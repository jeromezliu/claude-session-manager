import Cocoa
import WebKit

// Renders a mock (no personal data) screenshot of the app UI to a PNG via an
// offscreen WKWebView. Usage: swift docs/make-screenshot.swift [out.png]

let W: CGFloat = 1600, H: CGFloat = 940
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/screenshot.png"

let html = """
<!doctype html><html><head><meta charset="utf-8"><style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { width: \(Int(W))px; height: \(Int(H))px;
  background: linear-gradient(135deg,#e7ebf1,#d7dde6);
  font-family: -apple-system, 'SF Pro Text', system-ui, sans-serif; color: #1c1e22; }
.win { position: absolute; left: 40px; top: 36px; width: 1520px; height: 868px;
  background: #ffffff; border-radius: 12px; overflow: hidden;
  box-shadow: 0 24px 60px rgba(20,30,50,0.28); display: flex; flex-direction: column; }
.tbar { height: 52px; display: flex; align-items: center; padding: 0 16px; gap: 10px;
  border-bottom: 1px solid #ececf0; background: #fbfbfc; }
.lights { display: flex; gap: 8px; }
.lights i { width: 12px; height: 12px; border-radius: 50%; display: block; }
.title { font-weight: 600; font-size: 14px; margin-left: 8px; }
.tb-actions { margin-left: auto; display: flex; gap: 10px; color: #7a7f88; font-size: 15px; align-items: center; }
.tb-actions .btn { width: 30px; height: 26px; border-radius: 7px; background: #f0f1f3; display: flex; align-items: center; justify-content: center; }
.main { flex: 1; display: flex; min-height: 0; }
.side { width: 302px; background: #f4f5f7; border-right: 1px solid #e6e7ea; display: flex; flex-direction: column; }
.search { margin: 12px; height: 30px; border-radius: 8px; background: #e9eaee; display: flex; align-items: center; padding: 0 10px; color: #9a9ea6; font-size: 13px; gap: 6px; }
.tabs { display: flex; gap: 8px; padding: 0 12px 8px; }
.tab { font-size: 12.5px; font-weight: 600; padding: 4px 12px; border-radius: 8px; }
.tab.on { background: #4b8bf5; color: #fff; }
.tab.off { color: #6b7078; }
.sechdr { display:flex; align-items:center; gap:6px; padding: 6px 14px; color: #6b7078; font-size: 12px; font-weight: 600; }
.sechdr .count { margin-left:auto; color:#9a9ea6; }
.list { overflow: hidden; flex: 1; }
.row { padding: 9px 14px 9px 14px; display: flex; gap: 7px; }
.row.sel { background: #dfe9fd; }
.row .gut { width: 9px; padding-top: 5px; }
.dot { width: 7px; height: 7px; border-radius: 50%; background: #34c759; display: block; box-shadow: 0 0 6px rgba(52,199,89,0.6); }
.row .body { flex: 1; min-width: 0; }
.row .t { font-size: 13.5px; font-weight: 600; color:#1c1e22; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row.sel .t { color:#0b3d91; }
.row .s { font-size: 12px; color: #82868e; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 2px; }
.row .m { font-size: 11px; color: #a2a6ad; margin-top: 5px; display: flex; gap: 10px; }
.row .m .sp { margin-left: auto; }
.foot { border-top: 1px solid #e6e7ea; padding: 8px 12px; font-size: 11px; color: #8b8f97; }
.foot .path { font-size: 10.5px; color:#a2a6ad; margin-top:3px; }
.detail { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.dhead { padding: 16px 18px 12px; border-bottom: 1px solid #eee; }
.dhead .row1 { display:flex; align-items:flex-start; }
.dhead h1 { font-size: 17px; font-weight: 700; }
.dhead .p { font-size: 12px; color:#8b8f97; margin-top: 3px; }
.dhead .cont { margin-left:auto; background:#4b8bf5; color:#fff; font-size:13px; font-weight:600; padding:6px 14px; border-radius:8px; display:flex; gap:6px; align-items:center; }
.chips { display:flex; flex-wrap:wrap; gap:6px; margin-top:11px; }
.chip { font-size:11.5px; color:#6b7078; background:#f0f1f3; padding:3px 9px; border-radius:11px; }
.convo { flex:1; padding: 16px 18px; display:flex; flex-direction:column; gap:12px; overflow:hidden; }
.msg { border-radius:10px; padding:12px 14px; border:1px solid; }
.msg .hd { display:flex; align-items:center; gap:6px; font-size:12px; font-weight:700; margin-bottom:6px; }
.msg .hd .time { margin-left:auto; color:#a2a6ad; font-weight:500; font-size:11px; }
.msg .bd { font-size:13.5px; line-height:1.5; color:#2a2d33; }
.msg.assistant { background:#faf6fd; border-color:#efe3f7; }
.msg.assistant .hd { color:#8b3fc4; }
.msg.user { background:#eef4fd; border-color:#dbe8fb; }
.msg.user .hd { color:#2f6fd6; }
.mdot { width:8px;height:8px;border-radius:50%; display:block; }
.term { height: 268px; background:#14161d; display:flex; flex-direction:column; border-top:1px solid #000; }
.term .th { height:34px; background:#20232c; display:flex; align-items:center; gap:7px; padding:0 12px; color:#aeb4c0; font-size:12px; }
.term .th .g { color:#34c759; font-size:9px; }
.term .th .acts { margin-left:auto; color:#6b7280; display:flex; gap:12px; }
.term .body { flex:1; padding:12px 14px; font-family: 'SF Mono', ui-monospace, Menlo, monospace; font-size:12.5px; line-height:1.6; color:#c7cbd4; }
.term .p { color:#e8875f; }
.term .a { color:#e8875f; }
.term .muted { color:#8b93a3; }
.g-red{background:#ff5f57}.g-yel{background:#febc2e}.g-grn{background:#28c840}
svg { display:block; }
</style></head><body>
<div class="win">
  <div class="tbar">
    <div class="lights"><i class="g-red"></i><i class="g-yel"></i><i class="g-grn"></i></div>
    <div class="title">Claude Session Manager</div>
    <div class="tb-actions">
      <div class="btn">+</div><div class="btn">&#9662;</div>
      <div class="btn">&#9654;</div><div class="btn">&#9998;</div><div class="btn">&#128465;</div>
      <div class="btn">&#8943;</div><div class="btn">&#8635;</div>
    </div>
  </div>
  <div class="main">
    <div class="side">
      <div class="search">&#128269; Search sessions</div>
      <div class="tabs"><div class="tab on">Sessions</div><div class="tab off">Trash (2)</div></div>
      <div class="sechdr">&#128193; projects <span class="count">7</span></div>
      <div class="list">
        <div class="row"><div class="gut"><span class="dot"></span></div><div class="body"><div class="t">Refactor auth module</div><div class="s">async/await conversion is done</div><div class="m"><span>&#128172; 24</span><span>&#9636; 89.1k</span><span class="sp">2m ago</span></div></div></div>
        <div class="row sel"><div class="gut"></div><div class="body"><div class="t">Fix flaky payment tests</div><div class="s">the checkout suite fails intermittently</div><div class="m"><span>&#128172; 61</span><span>&#9636; 210.4k</span><span class="sp">18m ago</span></div></div></div>
        <div class="row"><div class="gut"></div><div class="body"><div class="t">Add dark mode to Settings</div><div class="s">wire up the appearance toggle</div><div class="m"><span>&#128172; 12</span><span>&#9636; 44.7k</span><span class="sp">1h ago</span></div></div></div>
        <div class="row"><div class="gut"></div><div class="body"><div class="t">Investigate slow dashboard query</div><div class="s">the analytics page takes ~4s to load</div><div class="m"><span>&#128172; 38</span><span>&#9636; 132.0k</span><span class="sp">3h ago</span></div></div></div>
        <div class="row"><div class="gut"></div><div class="body"><div class="t">Draft release notes for v2.3</div><div class="s">summarize the changelog since v2.2</div><div class="m"><span>&#128172; 7</span><span>&#9636; 15.2k</span><span class="sp">5h ago</span></div></div></div>
        <div class="row"><div class="gut"></div><div class="body"><div class="t">Set up CI pipeline</div><div class="s">add a GitHub Actions workflow</div><div class="m"><span>&#128172; 19</span><span>&#9636; 76.8k</span><span class="sp">1d ago</span></div></div></div>
        <div class="row"><div class="gut"></div><div class="body"><div class="t">Migrate storage to SwiftData</div><div class="s">replace the Core Data stack</div><div class="m"><span>&#128172; 45</span><span>&#9636; 188.3k</span><span class="sp">2d ago</span></div></div></div>
      </div>
      <div class="foot">7 projects &middot; 42 sessions<div class="path">&#128190; ~/.claude/projects</div></div>
    </div>
    <div class="detail">
      <div class="dhead">
        <div class="row1">
          <div><h1>Fix flaky payment tests</h1><div class="p">/Users/dev/projects/acme-web</div></div>
          <div class="cont">&#9654; Continue</div>
        </div>
        <div class="chips">
          <span class="chip">61 messages</span>
          <span class="chip">context 118.4k/200K &middot; 59%</span>
          <span class="chip">sonnet-5</span>
          <span class="chip">210.4k out tokens</span>
          <span class="chip">v2.1.0</span>
          <span class="chip">updated 18m ago</span>
          <span class="chip">1.4 MB</span>
        </div>
      </div>
      <div class="convo">
        <div class="msg assistant"><div class="hd"><span class="mdot" style="background:#b06fd8"></span>Assistant <span style="color:#a98bbf;font-weight:500">sonnet-5</span><span class="time">10:42</span></div><div class="bd">Found it. The checkout suite shared a single mock clock across tests, so timer-based retries raced under load. I isolated the clock per test and awaited the settlement explicitly — 200 runs, zero failures.</div></div>
        <div class="msg user"><div class="hd"><span class="mdot" style="background:#4b8bf5"></span>User<span class="time">10:41</span></div><div class="bd">Can you run it 200 times to be sure it's not flaky anymore?</div></div>
        <div class="msg assistant"><div class="hd"><span class="mdot" style="background:#b06fd8"></span>Assistant <span style="color:#a98bbf;font-weight:500">sonnet-5</span><span class="time">10:39</span></div><div class="bd">The intermittent failures come from `PaymentRetryTests` — they assert on wall-clock timing. I'll switch them to an injected clock and deterministic scheduling.</div></div>
        <div class="msg user"><div class="hd"><span class="mdot" style="background:#4b8bf5"></span>User<span class="time">10:38</span></div><div class="bd">The checkout test suite fails intermittently on CI. Can you dig in?</div></div>
      </div>
      <div class="term">
        <div class="th">&#9636; Terminal <span class="g">&#9679;</span><span class="acts">&#8598; &#9636; &#10005;</span></div>
        <div class="body">
          <div><span class="p">&#10095;</span> run the payment suite 200x</div>
          <div><span class="a">&#9679;</span> Running <span class="muted">PaymentRetryTests</span> 200 iterations with an injected clock&hellip;</div>
          <div>&nbsp;&nbsp;<span class="muted">200/200 passed &middot; 0 flaky &middot; 12.4s</span></div>
          <div><span class="a">&#9679;</span> All green. The suite is deterministic now.</div>
          <div><span class="p">&#10095;</span> &#9608;</div>
        </div>
      </div>
    </div>
  </div>
</div>
</body></html>
"""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    override init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: W, height: H), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = web
        web.navigationDelegate = self
    }
    func run() { web.loadHTMLString(html, baseURL: nil); app.run() }
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: W, height: H)
            cfg.snapshotWidth = NSNumber(value: Double(W))   // renders at ~2x device scale
            w.takeSnapshot(with: cfg) { image, err in
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("snapshot failed: \(String(describing: err))\n".data(using: .utf8)!)
                    exit(1)
                }
                try! png.write(to: URL(fileURLWithPath: out))
                print("wrote \(out) — \(rep.pixelsWide)x\(rep.pixelsHigh)")
                exit(0)
            }
        }
    }
}
Renderer().run()
