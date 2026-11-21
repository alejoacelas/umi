"""The debug socket of a UmiNext started with UMI_NEXT_DEBUG=1 (<state>/debug.sock, the protocol of
`umi-next-ui-debug`): one JSON command per connection, the reply read until the app closes it.
Every call has a timeout, so a reply that never comes fails the run instead of hanging it.

    from debugsock import Debug, Checks, poll
    dbg = Debug(state)
    D, ev, J = dbg, dbg.ev, dbg.J
"""
import json, os, socket, time

TIMEOUT = 30  # seconds for one command: connect, send and the whole reply


class Debug:
    def __init__(self, state, timeout=TIMEOUT, show_js=False):
        """show_js: a page error raised by ev() also carries the JS that failed."""
        self.path = os.path.join(state, "debug.sock")
        self.timeout = timeout
        self.show_js = show_js

    def __call__(self, cmd):
        """Sends one command; returns the app's reply."""
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(self.timeout)
        try:
            s.connect(self.path)
            s.sendall(json.dumps(cmd).encode() + b"\n")
            b = b""
            while (d := s.recv(1 << 20)):
                b += d
        finally:
            s.close()
        return json.loads(b)

    def result(self, js):
        """Evaluates JS in the page; returns its result as the app reports it, without checking for an error."""
        return self({"cmd": "eval", "js": js})["result"]

    def ev(self, js):
        """Evaluates JS in the page; a page error raises RuntimeError."""
        r = self({"cmd": "eval", "js": js})
        if r.get("error"):
            raise RuntimeError(r["error"] + ("\n" + js if self.show_js else ""))
        return r["result"]

    def J(self, js):
        """The value of a JS expression, through JSON."""
        return json.loads(self.ev("JSON.stringify(" + js + ")"))

    def spy_menu(self, pick=None, then=""):
        """The next bridge `menu` request is recorded in window.__menu (one {title, key, enabled,
        checked} per item, None for a separator) and answered with the item titled `pick` (None:
        dismissed); then runs the JS statement `then`, which can open the menu."""
        self.ev("""window.__menu = null; (() => { const orig = Umi.bridge.request;
      Umi.bridge.request = function (op, args, onEvent) {
        if (op !== 'menu') return orig.call(Umi.bridge, op, args, onEvent);
        Umi.bridge.request = orig;
        window.__menu = args.items.map((it) => (it.separator ? null
          : { title: it.title, key: it.key || null, enabled: it.enabled !== false, checked: !!it.checked }));
        const i = args.items.findIndex((it) => it.title === %s);
        return Promise.resolve({ index: i < 0 ? null : i });
      }; })(); %s; 1""" % (json.dumps(pick), then))


    def layout_ids(self):
        """{tabs: every tab's id, panes: every pane's id}, to give close_new() at the end."""
        return self.J("{ tabs: Umi.state.layout.tabs.map((t) => t.id), "
                      "panes: Umi.state.layout.tabs.flatMap((t) => Umi.model.paneIds(t.root)) }")

    def close_new(self, tabs, panes=None):
        """Ends the sessions of, and closes, every tab whose id is not in `tabs` and, with `panes`,
        every pane of the other tabs whose id is not in `panes`."""
        self.ev("""(() => { const keepTabs = new Set(%s), keepPanes = %s && new Set(%s), M = Umi.model;
  const doomed = Umi.state.layout.tabs.flatMap((t) => M.paneIds(t.root).filter((id) => !keepTabs.has(t.id) || (keepPanes && !keepPanes.has(id))));
  for (const id of doomed) { const s = M.sessionOf(id); if (s) Umi.bridge.post({ type: 'exitSession', session: s }); }
  Umi.app.update(() => doomed.forEach((id) => M.removePane(id)));
})(); 1""" % (json.dumps(tabs), json.dumps(panes is not None), json.dumps(panes or [])))


def poll(fn, secs, every=0.1, swallow=(), what=None):
    """Calls fn() every `every` seconds until it gives a truthy value, which it returns. After `secs`
    seconds it returns None, or with `what` raises AssertionError("timed out waiting for <what>").
    Exceptions of the types in `swallow` count as not yet."""
    end = time.time() + secs
    while time.time() < end:
        try:
            v = fn()
        except swallow:
            v = None
        if v:
            return v
        time.sleep(every)
    if what is not None:
        raise AssertionError("timed out waiting for " + what)
    return None


class Checks:
    """check(name, ok, detail=""): prints `ok   name` or `FAIL name` plus the detail in `fmt`, and
    collects the failed names in .fails. The detail shows only on a failure, and only when it is
    truthy unless `always`."""

    def __init__(self, fmt="  ({})", always=False):
        self.fmt, self.always, self.fails = fmt, always, []

    def __call__(self, name, ok, detail=""):
        shown = self.fmt.format(detail) if not ok and (self.always or detail) else ""
        print(("ok   " if ok else "FAIL ") + name + shown)
        if not ok:
            self.fails.append(name)
