// C glue over the vendored ffmpeg (build/build-ffmpeg.sh): the few calls src/formats/ffmpeg binds.
// Everything works on memory buffers; nothing touches the filesystem.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

typedef struct {
	const uint8_t *data;
	int64_t size, pos;
} Mem;

static int mem_read(void *opaque, uint8_t *buf, int n) {
	Mem *m = opaque;
	int64_t left = m->size - m->pos;
	if (left <= 0) return AVERROR_EOF;
	if (n > left) n = (int)left;
	memcpy(buf, m->data + m->pos, n);
	m->pos += n;
	return n;
}

static int64_t mem_seek(void *opaque, int64_t off, int whence) {
	Mem *m = opaque;
	switch (whence & ~AVSEEK_FORCE) {
	case AVSEEK_SIZE: return m->size;
	case SEEK_SET: break;
	case SEEK_CUR: off += m->pos; break;
	case SEEK_END: off += m->size; break;
	default: return -1;
	}
	if (off < 0 || off > m->size) return -1;
	return m->pos = off;
}

typedef struct {
	AVFormatContext *in, *out;
	AVIOContext *in_io;
	AVCodecContext *dec, *enc;
	SwrContext *swr;
	AVAudioFifo *fifo;
	AVPacket *pkt;
	AVFrame *frame, *chunk;
	int stream;
	int64_t pts;
	enum AVSampleFormat fmt; // what resample writes to the fifo
	int channels;
} Job;

static int drain(Job *j) {
	int r;
	while ((r = avcodec_receive_packet(j->enc, j->pkt)) >= 0) {
		av_packet_rescale_ts(j->pkt, j->enc->time_base, j->out->streams[0]->time_base);
		j->pkt->stream_index = 0;
		if ((r = av_interleaved_write_frame(j->out, j->pkt)) < 0) return r;
	}
	return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
}

// encode sends whole encoder frames from the fifo; with flush set, the short tail too.
static int encode(Job *j, int flush) {
	int size = j->enc->frame_size;
	while (av_audio_fifo_size(j->fifo) >= size || (flush && av_audio_fifo_size(j->fifo) > 0)) {
		int n = FFMIN(size, av_audio_fifo_size(j->fifo));
		av_frame_unref(j->chunk);
		j->chunk->nb_samples = n;
		j->chunk->format = j->enc->sample_fmt;
		j->chunk->sample_rate = j->enc->sample_rate;
		av_channel_layout_copy(&j->chunk->ch_layout, &j->enc->ch_layout);
		int r;
		if ((r = av_frame_get_buffer(j->chunk, 0)) < 0) return r;
		if (av_audio_fifo_read(j->fifo, (void **)j->chunk->data, n) < n) return AVERROR_BUG;
		j->chunk->pts = j->pts;
		j->pts += n;
		if ((r = avcodec_send_frame(j->enc, j->chunk)) < 0) return r;
		if ((r = drain(j)) < 0) return r;
	}
	return 0;
}

// resample converts one decoded frame (or, with f NULL, what swr still holds) into the fifo.
static int resample(Job *j, const AVFrame *f) {
	int in = f ? f->nb_samples : 0;
	int cap = swr_get_out_samples(j->swr, in);
	if (cap <= 0) return 0;
	uint8_t **buf = NULL;
	int r = av_samples_alloc_array_and_samples(&buf, NULL, j->channels, cap, j->fmt, 0);
	if (r < 0) return r;
	int n = swr_convert(j->swr, buf, cap, f ? (const uint8_t **)f->extended_data : NULL, in);
	if (n > 0 && av_audio_fifo_write(j->fifo, (void **)buf, n) < n) n = AVERROR(ENOMEM);
	av_freep(&buf[0]);
	av_freep(&buf);
	return n < 0 ? n : 0;
}

// decode sends one packet (NULL: flush) and resamples every frame it yields into the fifo.
static int decode(Job *j, const AVPacket *p) {
	int r = avcodec_send_packet(j->dec, p);
	if (r < 0 && r != AVERROR_EOF) return r;
	while ((r = avcodec_receive_frame(j->dec, j->frame)) >= 0) {
		r = resample(j, j->frame);
		av_frame_unref(j->frame);
		if (r < 0) return r;
	}
	return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
}

// read_all decodes the input's audio stream to its end, calling encode after each packet when set.
static int read_all(Job *j, int encoding) {
	int r;
	while ((r = av_read_frame(j->in, j->pkt)) >= 0) {
		if (j->pkt->stream_index == j->stream) {
			r = decode(j, j->pkt);
			if (r >= 0 && encoding) r = encode(j, 0);
		}
		av_packet_unref(j->pkt);
		if (r < 0) return r;
	}
	if (r != AVERROR_EOF) return r;
	if ((r = decode(j, NULL)) < 0) return r;
	return resample(j, NULL);
}

static int open_in(Job *j, Mem *m) {
	int r;
	uint8_t *iobuf = av_malloc(4096);
	if (!iobuf) return AVERROR(ENOMEM);
	j->in_io = avio_alloc_context(iobuf, 4096, 0, m, mem_read, NULL, mem_seek);
	if (!j->in_io) return av_free(iobuf), AVERROR(ENOMEM);
	j->in = avformat_alloc_context();
	if (!j->in) return AVERROR(ENOMEM);
	j->in->pb = j->in_io;
	if ((r = avformat_open_input(&j->in, NULL, NULL, NULL)) < 0) return r;
	if ((r = avformat_find_stream_info(j->in, NULL)) < 0) return r;
	const AVCodec *dc = NULL;
	if ((j->stream = av_find_best_stream(j->in, AVMEDIA_TYPE_AUDIO, -1, -1, &dc, 0)) < 0) return j->stream;
	if (!(j->dec = avcodec_alloc_context3(dc))) return AVERROR(ENOMEM);
	if ((r = avcodec_parameters_to_context(j->dec, j->in->streams[j->stream]->codecpar)) < 0) return r;
	return avcodec_open2(j->dec, dc, NULL);
}

static int open_out(Job *j, int bitrate) {
	int r;
	const AVCodec *ec = avcodec_find_encoder_by_name("libopus");
	if (!ec) return AVERROR_ENCODER_NOT_FOUND;
	if (!(j->enc = avcodec_alloc_context3(ec))) return AVERROR(ENOMEM);
	av_channel_layout_default(&j->enc->ch_layout, j->dec->ch_layout.nb_channels);
	j->enc->sample_rate = 48000; // Opus runs at 48 kHz
	j->enc->sample_fmt = AV_SAMPLE_FMT_FLT;
	j->enc->bit_rate = bitrate;
	j->enc->time_base = (AVRational){1, 48000};
	if ((r = avcodec_open2(j->enc, ec, NULL)) < 0) return r;

	if ((r = avformat_alloc_output_context2(&j->out, NULL, "ogg", NULL)) < 0) return r;
	if ((r = avio_open_dyn_buf(&j->out->pb)) < 0) return r;
	AVStream *st = avformat_new_stream(j->out, NULL);
	if (!st) return AVERROR(ENOMEM);
	st->time_base = j->enc->time_base;
	if ((r = avcodec_parameters_from_context(st->codecpar, j->enc)) < 0) return r;
	if ((r = avformat_write_header(j->out, NULL)) < 0) return r;

	if ((r = swr_alloc_set_opts2(&j->swr, &j->enc->ch_layout, j->enc->sample_fmt, j->enc->sample_rate,
	                             &j->dec->ch_layout, j->dec->sample_fmt, j->dec->sample_rate, 0, NULL)) < 0)
		return r;
	if ((r = swr_init(j->swr)) < 0) return r;
	j->fmt = j->enc->sample_fmt;
	j->channels = j->enc->ch_layout.nb_channels;
	if (!(j->fifo = av_audio_fifo_alloc(j->fmt, j->channels, j->enc->frame_size))) return AVERROR(ENOMEM);
	return 0;
}

// skyff_to_ogg transcodes one audio file in memory (any demuxer + decoder this build has) to Ogg
// Opus at bitrate bits/s per channel. On success *out holds the file; free it with skyff_free.
int skyff_to_ogg(const uint8_t *in, int64_t size, int bitrate, uint8_t **out, int64_t *out_size) {
	Mem m = {in, size, 0};
	Job j = {0};
	int r;
	*out = NULL;
	*out_size = 0;
	av_log_set_level(AV_LOG_QUIET); // failures come back as codes; warnings are per-file noise
	if (!(j.pkt = av_packet_alloc()) || !(j.frame = av_frame_alloc()) || !(j.chunk = av_frame_alloc())) {
		r = AVERROR(ENOMEM);
		goto done;
	}
	if ((r = open_in(&j, &m)) < 0 || (r = open_out(&j, bitrate * j.dec->ch_layout.nb_channels)) < 0) goto done;

	if ((r = read_all(&j, 1)) < 0 || (r = encode(&j, 1)) < 0) goto done;
	if ((r = avcodec_send_frame(j.enc, NULL)) < 0 || (r = drain(&j)) < 0) goto done;
	if ((r = av_write_trailer(j.out)) < 0) goto done;
	*out_size = avio_close_dyn_buf(j.out->pb, out);
	j.out->pb = NULL;
	r = 0;

done:
	if (j.out) {
		if (j.out->pb) {
			uint8_t *junk;
			avio_close_dyn_buf(j.out->pb, &junk);
			av_free(junk);
		}
		avformat_free_context(j.out);
	}
	avformat_close_input(&j.in);
	if (j.in_io) av_freep(&j.in_io->buffer);
	avio_context_free(&j.in_io);
	avcodec_free_context(&j.dec);
	avcodec_free_context(&j.enc);
	swr_free(&j.swr);
	if (j.fifo) av_audio_fifo_free(j.fifo);
	av_packet_free(&j.pkt);
	av_frame_free(&j.frame);
	av_frame_free(&j.chunk);
	return r;
}

// skyff_decode decodes one audio file in memory to interleaved float samples at its own rate.
// On success *out holds frames * channels floats; free it with skyff_free.
int skyff_decode(const uint8_t *in, int64_t size, float **out, int64_t *frames, int *rate, int *channels) {
	Mem m = {in, size, 0};
	Job j = {0};
	int r;
	*out = NULL;
	*frames = 0;
	av_log_set_level(AV_LOG_QUIET);
	if (!(j.pkt = av_packet_alloc()) || !(j.frame = av_frame_alloc())) {
		r = AVERROR(ENOMEM);
		goto done;
	}
	if ((r = open_in(&j, &m)) < 0) goto done;
	j.fmt = AV_SAMPLE_FMT_FLT;
	j.channels = j.dec->ch_layout.nb_channels;
	if ((r = swr_alloc_set_opts2(&j.swr, &j.dec->ch_layout, j.fmt, j.dec->sample_rate,
	                             &j.dec->ch_layout, j.dec->sample_fmt, j.dec->sample_rate, 0, NULL)) < 0 ||
	    (r = swr_init(j.swr)) < 0)
		goto done;
	if (!(j.fifo = av_audio_fifo_alloc(j.fmt, j.channels, 4096))) {
		r = AVERROR(ENOMEM);
		goto done;
	}
	if ((r = read_all(&j, 0)) < 0) goto done;

	int n = av_audio_fifo_size(j.fifo);
	if (!(*out = av_malloc((size_t)n * j.channels * sizeof(float)))) {
		r = AVERROR(ENOMEM);
		goto done;
	}
	void *planes[1] = {*out};
	av_audio_fifo_read(j.fifo, planes, n);
	*frames = n;
	*rate = j.dec->sample_rate;
	*channels = j.channels;
	r = 0;

done:
	avformat_close_input(&j.in);
	if (j.in_io) av_freep(&j.in_io->buffer);
	avio_context_free(&j.in_io);
	avcodec_free_context(&j.dec);
	swr_free(&j.swr);
	if (j.fifo) av_audio_fifo_free(j.fifo);
	av_packet_free(&j.pkt);
	av_frame_free(&j.frame);
	return r;
}

void skyff_free(uint8_t *p) {
	av_free(p);
}

// skyff_error writes ffmpeg's message for an error code into buf.
void skyff_error(int code, char *buf, int64_t size) {
	av_strerror(code, buf, (size_t)size);
}
