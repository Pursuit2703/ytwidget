.pragma library

var MAX_SOCKET_LINE = 262144

function assign(target, source) {
  var next = target && typeof target === "object" && !Array.isArray(target)
    ? target : ({})
  if (!source || typeof source !== "object" || Array.isArray(source)) return next
  for (var key in source) next[key] = source[key]
  return next
}

function parseJson(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed === null ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function splitSocketBuffer(buffer, chunk, maxBytes) {
  var limit = Number(maxBytes)
  if (!isFinite(limit) || limit <= 0) limit = MAX_SOCKET_LINE
  var next = String(buffer || "") + String(chunk || "")
  if (next.length > limit && next.indexOf("\n") < 0)
    return { overflow: true, buffer: "", lines: [] }
  var lines = []
  var start = 0
  while (true) {
    var idx = next.indexOf("\n", start)
    if (idx < 0) break
    var line = next.slice(start, idx)
    if (line.length > limit)
      return { overflow: true, buffer: "", lines: [] }
    lines.push(line)
    start = idx + 1
  }
  var rest = next.slice(start)
  if (rest.length > limit)
    return { overflow: true, buffer: "", lines: [] }
  return { overflow: false, buffer: rest, lines: lines }
}

// Mirrors urls.looks_like_url() in the backend: decides whether the search
// box should expand a link instead of running a text search. Kept cheap and
// permissive here — the backend's parser is the authority on what it means.
function isYouTubeLink(text) {
  var value = String(text || "").trim()
  if (!value || value.indexOf(" ") >= 0) return false
  return /^(https?:\/\/|\/\/)?(www\.|m\.|music\.)?(youtube\.com|youtu\.be)\//i.test(value)
}

function barTrackText(title, artist, showTitle, showArtist) {
  var cleanTitle = String(title || "").trim()
  var cleanArtist = String(artist || "").trim()
  var parts = []
  if (showArtist && cleanArtist) parts.push(cleanArtist)
  if (showTitle && cleanTitle) parts.push(cleanTitle)
  return parts.join(" - ")
}

function formatTime(ms) {
  var total = Math.max(0, Math.floor(Number(ms) / 1000))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  if (h > 0) return h + ":" + pad(m) + ":" + pad(s)
  return m + ":" + pad(s)
}
