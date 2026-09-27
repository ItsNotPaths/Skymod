use ba2::{
    prelude::*,
    tes4::{Archive, ArchiveFlags, ArchiveKey, ArchiveOptions, Directory, DirectoryKey, File, Version},
};
use std::{
    error::Error,
    ffi::{c_char, CStr},
    fs,
    io::{BufWriter, Write},
};

#[repr(C)]
pub struct SkyBsaEntry {
    path: *const c_char, // archive path, "sound\voice\...\x.ogg"
    offset: u64,         // where its bytes start in the spool
    size: u64,
}

/// Packs entries, whose bytes lie in the spool file, into an uncompressed v105 archive at out.
#[no_mangle]
pub unsafe extern "C" fn skybsa_pack(
    out: *const c_char,
    spool: *const c_char,
    entries: *const SkyBsaEntry,
    n: usize,
) -> bool {
    let entries = if n == 0 { &[][..] } else { std::slice::from_raw_parts(entries, n) };
    match pack(CStr::from_ptr(out), CStr::from_ptr(spool), entries) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("skybsa_pack: {e}");
            false
        }
    }
}

unsafe fn pack(out: &CStr, spool: &CStr, entries: &[SkyBsaEntry]) -> Result<(), Box<dyn Error>> {
    let map = memmap2::Mmap::map(&fs::File::open(utf8(spool)?)?)?;
    let archive = build(&map, entries)?;
    let options = ArchiveOptions::builder()
        .version(Version::v105)
        .flags(ArchiveFlags::DIRECTORY_STRINGS | ArchiveFlags::FILE_STRINGS)
        .build();
    let mut w = BufWriter::new(fs::File::create(utf8(out)?)?);
    archive.write(&mut w, &options)?;
    w.flush()?;
    Ok(())
}

unsafe fn build<'a>(spool: &'a [u8], entries: &[SkyBsaEntry]) -> Result<Archive<'a>, Box<dyn Error>> {
    let mut archive = Archive::new();
    for e in entries {
        let path = CStr::from_ptr(e.path).to_bytes();
        let cut = path.iter().rposition(|&c| c == b'\\' || c == b'/').ok_or("path has no folder")?;
        let bytes = spool
            .get(usize::try_from(e.offset)?..usize::try_from(e.offset + e.size)?)
            .ok_or("entry lies past the spool's end")?;
        let file = File::from_decompressed(bytes);
        let key: ArchiveKey<'a> = path[..cut].into();
        let name: DirectoryKey<'a> = path[cut + 1..].into();
        match archive.get_mut(key.hash()) {
            Some(dir) => {
                dir.insert(name, file);
            }
            None => {
                let mut dir = Directory::new();
                dir.insert(name, file);
                archive.insert(key, dir);
            }
        }
    }
    Ok(archive)
}

fn utf8(s: &CStr) -> Result<&str, Box<dyn Error>> {
    Ok(s.to_str()?)
}
