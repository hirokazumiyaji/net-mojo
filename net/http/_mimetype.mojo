"""Static extension types and a bounded content signature probe."""

comptime _MIME_TABLE: StaticString = """html	text/html; charset=utf-8
htm	text/html; charset=utf-8
css	text/css; charset=utf-8
txt	text/plain; charset=utf-8
text	text/plain; charset=utf-8
md	text/markdown; charset=utf-8
markdown	text/markdown; charset=utf-8
csv	text/csv; charset=utf-8
tsv	text/tab-separated-values; charset=utf-8
xml	text/xml; charset=utf-8
xhtml	application/xhtml+xml
js	application/javascript
mjs	application/javascript
json	application/json
map	application/json
webmanifest	application/manifest+json
pdf	application/pdf
wasm	application/wasm
bin	application/octet-stream
exe	application/octet-stream
dll	application/octet-stream
so	application/octet-stream
dylib	application/octet-stream
zip	application/zip
gz	application/gzip
tgz	application/gzip
tar	application/x-tar
bz2	application/x-bzip2
xz	application/x-xz
7z	application/x-7z-compressed
rar	application/vnd.rar
zst	application/zstd
png	image/png
jpg	image/jpeg
jpeg	image/jpeg
gif	image/gif
svg	image/svg+xml
svgz	image/svg+xml
webp	image/webp
avif	image/avif
apng	image/apng
bmp	image/bmp
ico	image/x-icon
tif	image/tiff
tiff	image/tiff
heic	image/heic
heif	image/heif
woff	font/woff
woff2	font/woff2
ttf	font/ttf
otf	font/otf
eot	application/vnd.ms-fontobject
mp3	audio/mpeg
wav	audio/wav
ogg	audio/ogg
oga	audio/ogg
opus	audio/opus
flac	audio/flac
aac	audio/aac
m4a	audio/mp4
mid	audio/midi
midi	audio/midi
mp4	video/mp4
m4v	video/mp4
webm	video/webm
ogv	video/ogg
mov	video/quicktime
avi	video/x-msvideo
mpeg	video/mpeg
mpg	video/mpeg
ics	text/calendar; charset=utf-8
vcf	text/vcard; charset=utf-8
rtf	application/rtf
doc	application/msword
docx	application/vnd.openxmlformats-officedocument.wordprocessingml.document
xls	application/vnd.ms-excel
xlsx	application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
ppt	application/vnd.ms-powerpoint
pptx	application/vnd.openxmlformats-officedocument.presentationml.presentation
odt	application/vnd.oasis.opendocument.text
ods	application/vnd.oasis.opendocument.spreadsheet
odp	application/vnd.oasis.opendocument.presentation
epub	application/epub+zip
atom	application/atom+xml
rss	application/rss+xml
yaml	application/yaml
yml	application/yaml
toml	application/toml
sqlite	application/vnd.sqlite3
sqlite3	application/vnd.sqlite3"""


def _prefix[
    origin: ImmOrigin, pattern_origin: ImmOrigin
](
    data: Span[Byte, origin],
    pattern: Span[Byte, pattern_origin],
    start: Int = 0,
) -> Bool:
    if len(data) < start + len(pattern):
        return False
    for i in range(len(pattern)):
        if data[start + i] != pattern[i]:
            return False
    return True


def _sniff[origin: ImmOrigin](sample: Span[Byte, origin]) -> String:
    var data = sample[: min(len(sample), 512)]
    var png: Array[Byte, 8] = [137, 80, 78, 71, 13, 10, 26, 10]
    var jpeg: Array[Byte, 3] = [255, 216, 255]
    var ico: Array[Byte, 4] = [0, 0, 1, 0]
    var gzip: Array[Byte, 3] = [31, 139, 8]
    var wasm: Array[Byte, 4] = [0, 97, 115, 109]
    if _prefix(data, Span(png)):
        return "image/png"
    if _prefix(data, Span(jpeg)):
        return "image/jpeg"
    if _prefix(data, "GIF87a".as_bytes()) or _prefix(data, "GIF89a".as_bytes()):
        return "image/gif"
    if _prefix(data, Span(ico)):
        return "image/x-icon"
    if _prefix(data, "%PDF-".as_bytes()):
        return "application/pdf"
    if _prefix(data, Span(gzip)):
        return "application/gzip"
    if _prefix(data, Span(wasm)):
        return "application/wasm"
    if (
        _prefix(data, "PK".as_bytes())
        and len(data) >= 4
        and (
            (data[2] == 3 and data[3] == 4)
            or (data[2] == 5 and data[3] == 6)
            or (data[2] == 7 and data[3] == 8)
        )
    ):
        return "application/zip"
    if _prefix(data, "RIFF".as_bytes()):
        if _prefix(data, "WEBP".as_bytes(), 8):
            return "image/webp"
        if _prefix(data, "WAVE".as_bytes(), 8):
            return "audio/wav"
        if _prefix(data, "AVI ".as_bytes(), 8):
            return "video/x-msvideo"
    if _prefix(data, "OggS".as_bytes()):
        return "application/ogg"
    if _prefix(data, "ID3".as_bytes()):
        return "audio/mpeg"
    if _prefix(data, "ftyp".as_bytes(), 4):
        return "video/mp4"
    var start = 0
    while start < len(data) and (
        data[start] == 32
        or data[start] == 9
        or data[start] == 10
        or data[start] == 12
        or data[start] == 13
    ):
        start += 1
    var text = String(from_utf8_lossy=data[start:]).upper()
    for signature in [
        "<!DOCTYPE HTML",
        "<HTML",
        "<HEAD",
        "<BODY",
        "<SCRIPT",
        "<IFRAME",
        "<DIV",
        "<TITLE",
        "<H1",
    ]:
        if text.startswith(signature):
            var after = String(signature).byte_length()
            if text.byte_length() > after:
                var byte = text.as_bytes()[after]
                if byte == 32 or byte == 62:
                    return "text/html; charset=utf-8"
    if text.startswith("<!--"):
        return "text/html; charset=utf-8"
    if text.startswith("<?XML"):
        return "text/xml; charset=utf-8"
    for byte in data:
        if byte < 32 and byte != 9 and byte != 10 and byte != 12 and byte != 13:
            return "application/octet-stream"
    return "text/plain; charset=utf-8"


def _mime_type[
    origin: ImmOrigin
](name: StringSlice, sample: Span[Byte, origin]) -> String:
    var bytes = name.as_bytes()
    var dot = -1
    for i in range(len(bytes) - 1, -1, -1):
        if bytes[i] == 47:
            break
        if bytes[i] == 46:
            dot = i
            break
    if dot >= 0:
        var extension = String(from_utf8_lossy=bytes[dot + 1 :]).lower()
        for line in _MIME_TABLE.split("\n"):
            var pair = line.split("\t")
            if extension == pair[0]:
                return String(pair[1])
    return _sniff(sample)
