import QtQuick
import qs.Commons

// Colours taken from the cover art, so the player looks like the song.
//
// The thumbnail is drawn 24 px square into a Canvas and the pixels are
// bucketed by hue, weighted by saturation, so the strongest real colour of
// the picture wins over large grey or black areas. From that one hue come:
//
//   accent    bright enough to read on the dark surfaces (buttons, bars)
//   onAccent  text/glyph colour that sits on the accent
//   glow      a mid tone for the soft wash behind the top of a page
//   deep      a dark tinted surface (panes, the player bar)
//
// A greyscale cover, a missing thumbnail or a light theme fall back to the
// theme accent, so nothing becomes unreadable. Colours glide when the song
// changes.
//
// The Canvas has to be visible to paint, so place this item where other
// content covers it (it is 24 px).
Item {
  id: root

  property string source: ""
  property color fallback: Color.accent
  property color base: Color.background

  readonly property bool darkTheme: luminance(base) < 0.5
  property bool found: false
  property real hue: 0
  property real sat: 0

  readonly property color accent: !found ? fallback
    : Qt.hsla(hue, clamp(sat * 1.15, 0.45, 0.85), darkTheme ? 0.70 : 0.40, 1)
  readonly property color onAccent: luminance(accent) > 0.45 ? Qt.rgba(0.08, 0.07, 0.06, 1) : "#ffffff"
  readonly property color glow: !found ? Qt.rgba(fallback.r, fallback.g, fallback.b, 0.18)
    : Qt.hsla(hue, clamp(sat * 0.7, 0.25, 0.6), darkTheme ? 0.26 : 0.86, 1)
  readonly property color deep: !found ? base
    : Qt.hsla(hue, clamp(sat * 0.45, 0.15, 0.4), darkTheme ? 0.115 : 0.94, 1)

  // Animated copies for the UI to bind to.
  property color accentAnimated: accent
  property color glowAnimated: glow
  property color deepAnimated: deep
  Behavior on accentAnimated { ColorAnimation { duration: 600; easing.type: Easing.OutCubic } }
  Behavior on glowAnimated { ColorAnimation { duration: 600; easing.type: Easing.OutCubic } }
  Behavior on deepAnimated { ColorAnimation { duration: 600; easing.type: Easing.OutCubic } }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function luminance(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

  width: 24
  height: 24

  onSourceChanged: if (source === "") found = false

  Image {
    id: img
    width: 24
    height: 24
    visible: false
    source: root.source
    asynchronous: true
    cache: true
    // No sourceSize: a scaled decode reads back as all-black pixels.
    onStatusChanged: {
      if (status === Image.Ready) canvas.requestPaint()
      else if (status === Image.Error) root.found = false
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    // Painted only to be read back; never meant to be seen.
    opacity: 0.01
    renderTarget: Canvas.Image
    onPaint: {
      if (img.status !== Image.Ready) return
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, 24, 24)
      ctx.drawImage(img, 0, 0, 24, 24)
      var d = ctx.getImageData(0, 0, 24, 24).data
      var buckets = []
      for (var b = 0; b < 18; b++) buckets.push({ w: 0, r: 0, g: 0, bl: 0 })
      var total = 0
      for (var i = 0; i < d.length; i += 4) {
        var r = d[i] / 255, g = d[i + 1] / 255, bl = d[i + 2] / 255
        var mx = Math.max(r, g, bl), mn = Math.min(r, g, bl)
        var v = mx, s = mx > 0 ? (mx - mn) / mx : 0
        if (v < 0.12 || s < 0.12) continue
        var h
        if (mx === mn) h = 0
        else if (mx === r) h = ((g - bl) / (mx - mn)) % 6
        else if (mx === g) h = (bl - r) / (mx - mn) + 2
        else h = (r - g) / (mx - mn) + 4
        h = (h * 60 + 360) % 360
        var w = s * s * Math.min(1, v * 1.4)
        var k = Math.floor(h / 20) % 18
        buckets[k].w += w; buckets[k].r += r * w; buckets[k].g += g * w; buckets[k].bl += bl * w
        total += w
      }
      var best = null
      for (var j = 0; j < 18; j++) if (!best || buckets[j].w > best.w) best = buckets[j]
      // Barely any colour in the picture: keep the theme accent.
      if (!best || best.w < 4 || total <= 0) { root.found = false; return }
      var c = Qt.rgba(best.r / best.w, best.g / best.w, best.bl / best.w, 1)
      root.hue = Math.max(0, c.hslHue)
      root.sat = Math.max(0, c.hslSaturation)
      root.found = true
    }
  }
}
