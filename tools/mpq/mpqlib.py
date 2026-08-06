"""Minimal StormLib binding for reading and modifying WoW 3.3.5a MPQ archives.

Only what the patch workflow needs: enumerate, extract, and add/replace a file
inside an EXISTING archive.

There is deliberately no "build an archive from a list of files" here. Rebuilding
patch-enUS-U from a file list would silently drop anything not on that list, and
the whole point of the consolidated archive is that it accumulates DBCs over
time. Opening the archive and swapping one entry cannot lose what it never
touches.

Set UNCAPPED_STORMLIB to override the DLL location.
"""
import ctypes
import hashlib
import os

DLL = os.environ.get(
    'UNCAPPED_STORMLIB',
    r'C:\Users\sloth\Desktop\New folder (2)\x64\StormLib.dll')

if not os.path.exists(DLL):
    raise SystemExit(
        'StormLib.dll not found at %s\n'
        'Set UNCAPPED_STORMLIB to its path.' % DLL)

s = ctypes.WinDLL(DLL)

MPQ_FILE_REPLACEEXISTING = 0x80000000
MPQ_COMPRESSION_ZLIB     = 0x02
STREAM_FLAG_READ_ONLY    = 0x100

# The compression argument to SFileWriteFile is only consulted when the file was
# CREATED asking to be compressed. Without this bit in SFileCreateFile's flags,
# StormLib stores the payload raw and silently ignores MPQ_COMPRESSION_ZLIB --
# there is no error and the archive is perfectly valid, just enormous.
#
# Measured 2026-08-06 adding a 49.5 MB Spell.dbc to patch-enUS-U:
#     without the flag   56,330,243 bytes
#     with it            11,336,350 bytes
# Byte-identical on read-back either way, which is exactly why this went unnoticed:
# build-patch.py verifies CONTENT, and the content was always correct.
MPQ_FILE_COMPRESS        = 0x00000200

# SFILE_FIND_DATA on this x64 Windows build. Probed empirically rather than
# assumed: a pointer scan located szPlainName at +264 pointing back into
# cFileName, which pins cFileName[MAX_PATH=260] plus 4 bytes of alignment.
#     0    char  cFileName[260]
#     264  char *szPlainName
#     272  DWORD dwHashIndex
#     276  DWORD dwBlockIndex
#     280  DWORD dwFileSize
FD_SIZE, FD_NAME, FD_FILESIZE = 512, 0, 280

s.SFileOpenArchive.argtypes   = [ctypes.c_wchar_p, ctypes.c_uint, ctypes.c_uint,
                                 ctypes.POINTER(ctypes.c_void_p)]
s.SFileCloseArchive.argtypes  = [ctypes.c_void_p]
s.SFileOpenFileEx.argtypes    = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint,
                                 ctypes.POINTER(ctypes.c_void_p)]
s.SFileGetFileSize.argtypes   = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
s.SFileReadFile.argtypes      = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                 ctypes.POINTER(ctypes.c_uint), ctypes.c_void_p]
s.SFileCloseFile.argtypes     = [ctypes.c_void_p]
s.SFileFindFirstFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p,
                                 ctypes.c_wchar_p]
s.SFileFindFirstFile.restype  = ctypes.c_void_p
s.SFileFindNextFile.argtypes  = [ctypes.c_void_p, ctypes.c_void_p]
s.SFileFindClose.argtypes     = [ctypes.c_void_p]
s.SFileCreateFile.argtypes    = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_ulonglong,
                                 ctypes.c_uint, ctypes.c_uint, ctypes.c_uint,
                                 ctypes.POINTER(ctypes.c_void_p)]
s.SFileWriteFile.argtypes     = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                 ctypes.c_uint]
s.SFileFinishFile.argtypes    = [ctypes.c_void_p]
s.SFileSetMaxFileCount.argtypes = [ctypes.c_void_p, ctypes.c_uint]

# StormLib is C++ and these return `bool`, which the ABI passes in AL only --
# the upper 24 bits of EAX are garbage. Read as the default c_int, a FALSE
# becomes a large non-zero number and SFileFindNextFile's loop never terminates.
# c_bool reads the single byte the callee actually set. This cost an hour once;
# do not "simplify" it away.
for _fn in (s.SFileOpenArchive, s.SFileCloseArchive, s.SFileOpenFileEx,
            s.SFileReadFile, s.SFileCloseFile, s.SFileFindNextFile,
            s.SFileFindClose, s.SFileCreateFile, s.SFileWriteFile,
            s.SFileFinishFile, s.SFileSetMaxFileCount):
    _fn.restype = ctypes.c_bool

# MPQ bookkeeping, not content the game reads.
INTERNAL = ('(listfile)', '(attributes)', '(signature)', '(user data)')


def _open(path, readonly=True):
    h = ctypes.c_void_p()
    flags = STREAM_FLAG_READ_ONLY if readonly else 0
    if not s.SFileOpenArchive(path, 0, flags, ctypes.byref(h)):
        raise RuntimeError('could not open %s (%d)' % (path, ctypes.get_last_error()))
    return h


def listfiles(path):
    """Every entry in the archive as (name, uncompressed_size).

    Enumerates the hash/block tables via SFileFindFirstFile rather than reading
    (listfile), which may be absent or incomplete -- the tables are ground truth.
    """
    h = _open(path)
    try:
        buf = ctypes.create_string_buffer(FD_SIZE)
        found = s.SFileFindFirstFile(h, b'*', buf, None)
        if not found:
            return []
        hf = ctypes.c_void_p(found)
        out = []
        while True:
            name = ctypes.string_at(ctypes.addressof(buf) + FD_NAME).decode('ascii', 'replace')
            out.append((name, ctypes.c_uint.from_buffer(buf, FD_FILESIZE).value))
            if not s.SFileFindNextFile(hf, buf):
                break
        s.SFileFindClose(hf)
        return out
    finally:
        s.SFileCloseArchive(h)


def content_files(path):
    """listfiles() minus the MPQ's own bookkeeping entries."""
    return [(n, sz) for n, sz in listfiles(path) if n not in INTERNAL]


def extract(path, name):
    h = _open(path)
    try:
        f = ctypes.c_void_p()
        if not s.SFileOpenFileEx(h, name.encode('ascii'), 0, ctypes.byref(f)):
            raise KeyError('%s is not in %s' % (name, path))
        hi = ctypes.c_uint(0)
        size = s.SFileGetFileSize(f, ctypes.byref(hi))
        buf = ctypes.create_string_buffer(size)
        got = ctypes.c_uint(0)
        s.SFileReadFile(f, buf, size, ctypes.byref(got), None)
        s.SFileCloseFile(f)
        return buf.raw[:got.value]
    finally:
        s.SFileCloseArchive(h)


def digest(path, name):
    return hashlib.sha256(extract(path, name)).hexdigest()


def add_files(archive, entries, max_files=64):
    """Add or replace entries in an existing archive, in place.

    entries: iterable of (entry_name, bytes).

    max_files grows the hash table -- an archive packed for exactly N files
    cannot accept an N+1th without it.
    """
    h = _open(archive, readonly=False)
    try:
        s.SFileSetMaxFileCount(h, max_files)
        for name, payload in entries:
            f = ctypes.c_void_p()
            if not s.SFileCreateFile(h, name.encode('ascii'), 0, len(payload), 0,
                                     MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING,
                                     ctypes.byref(f)):
                raise RuntimeError('SFileCreateFile(%s) failed (%d)'
                                   % (name, ctypes.get_last_error()))
            if not s.SFileWriteFile(f, payload, len(payload), MPQ_COMPRESSION_ZLIB):
                s.SFileFinishFile(f)
                raise RuntimeError('SFileWriteFile(%s) failed (%d)'
                                   % (name, ctypes.get_last_error()))
            s.SFileFinishFile(f)
    finally:
        s.SFileCloseArchive(h)
