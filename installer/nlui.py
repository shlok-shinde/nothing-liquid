"""
Shared parts of Nothing Liquid's installers (the desktop one, and the one on the
USB image): the look (styles, the row of dots, small widget helpers), the
terminal session their steps run in (Runner), and the details log and question
dialogs around it (RunnerUI).
"""

import codecs
import fcntl
import math
import os
import pty
import re
import signal
import struct
import termios

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango

RED = (0xD7 / 255, 0x19 / 255, 0x21 / 255)

# What you can pick, and what to try first: the same in both installers
ACCENTS = [("Nothing red", "#D71921"), ("White", "#F2F2F2"), ("Your wallpaper's colours", "")]
FONTS = [("Clean (Google Sans Flex)", "clean"),
         ("Dot-matrix clock and titles", "titles"),
         ("Dot-matrix everywhere, like the screenshots", "all")]
SHOTS = ["windows-body-lens.png", "launcher-bright-wallpaper.png", "lock-screen-glass.png", "power-menu-glass.png"]
KEYS = [("SUPER", "Search and open apps"), ("SUPER + Enter", "Terminal"), ("SUPER + E", "Files"),
        ("SUPER + W", "Browser"), ("SUPER + Q", "Close a window"), ("SUPER + H", "Minimize into the dock"),
        ("CTRL + SUPER + T", "Pick a wallpaper"), ("SUPER + /", "Every shortcut")]
SUDO_MARK = "NL-SUDO-PASSWORD:"  # sudo's prompt in our session (SUDO_PROMPT), in any language

# ── one terminal session for all the steps ───────────────────────────────────
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
MARK = re.compile(r"@@NL(DONE|READY)(?: (-?\d+))?@@")


class Runner:
    """A bash in a pseudo-terminal of its own. Steps run in it one after another, so
    sudo's remembered password (kept per terminal) carries over from one to the next."""

    def __init__(self, log_path, on_line, on_live, on_ready, on_done, on_prompt, on_exit, cwd="/"):
        self.log = open(log_path, "a", buffering=1)
        self.cwd = cwd
        self.on_line, self.on_live, self.on_ready = on_line, on_live, on_ready
        self.on_done, self.on_prompt, self.on_exit = on_done, on_prompt, on_exit
        self.pid = self.fd = None
        self.ready = False
        self.live = ""
        self.carriage = False
        self.carry = ""
        self.line_no = 0
        self.prompted = -1
        self.recent = []
        self.stall = 0
        self.after_answer = False
        self.finished = 0  # steps ended so far

    def start(self):
        env = dict(os.environ)
        env.update({
            "SUDO_PROMPT": SUDO_MARK, "TERM": "xterm-256color", "HISTFILE": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "PAGER": "cat", "SYSTEMD_PAGER": "", "PS1": "", "PS2": "",
            "LANGUAGE": "", "LC_MESSAGES": "C.UTF-8", "COLUMNS": "120", "LINES": "40",
        })
        if "LC_ALL" in env:  # it would override LC_MESSAGES: keep it as LANG instead
            env["LANG"] = env.pop("LC_ALL")
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(self.cwd)
                os.execvpe("bash", ["bash", "--noprofile", "--norc", "--noediting", "-i"], env)
            finally:
                os._exit(127)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        GLib.io_add_watch(fd, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self._readable)
        self.write("stty -echo; set +m; unset PROMPT_COMMAND; "
                   "nl_keepalive() { ( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & NL_KEEPALIVE=$!; }; "
                   "nl_finish() { [ -n \"${NL_KEEPALIVE:-}\" ] && kill \"$NL_KEEPALIVE\" 2>/dev/null; true; }; "
                   "printf '@@NL%s@@\\n' READY\n")

    def write(self, text):
        if self.fd is not None:
            os.write(self.fd, text.encode())

    def run(self, command):
        # One line: a command that reads its input must not swallow the marker
        assert "\n" not in command
        self.prompted = -1
        self.write(f"{command}; printf '@@NL%s %d@@\\n' DONE $?\n")

    def answer(self, text, token, secret=False):
        """Answer the question asked on line `token`, if it's still the one waiting:
        a late answer must never reach the shell itself (it would run as a command)."""
        if token != self.line_no or self.fd is None:
            return False
        shown = self.live.rstrip()
        if secret or SUDO_MARK in shown:
            shown = shown.replace(SUDO_MARK, "[password]") + " ••••••"
        elif text:
            shown += " " + text
        self.live, self.carriage = "", False
        self.line_no += 1
        self.after_answer = True  # with echo off, the answer's own newline shows as an empty line
        self._emit(shown)
        self.on_live("")
        self.write(text + "\n")
        return True

    def interrupt(self):
        """Ctrl+C, as in a terminal. When it kills the command, bash drops the rest of
        that line, the step's end marker with it: then say it ended (130) ourselves."""
        self.write("\x03")
        GLib.timeout_add(1500, self._after_interrupt, self.finished)

    def _after_interrupt(self, finished):
        if self.fd is not None and finished == self.finished:
            self.write("printf '@@NL%s %d@@\\n' DONE 130\n")
        return False

    def close(self):
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGHUP)
            except OSError:
                pass
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
        self.fd = self.pid = None
        self.log.close()

    def _readable(self, fd, condition):
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            if self.fd is not None:
                self.fd = None
                self.on_exit()
            return False
        self._feed(self.decoder.decode(data))
        return True

    def _feed(self, text):
        text = self.carry + text
        self.carry = ""
        cut = text.rfind("\x1b")  # an escape sequence split between two reads
        if cut != -1 and not ANSI.match(text, cut) and len(text) - cut < 32:
            text, self.carry = text[:cut], text[cut:]
        text = ANSI.sub(lambda m: m.group(0) if m.group(0) in "\r\n" else "", text)
        for part in re.split(r"(\r\n|\n|\r)", text):
            if part in ("\n", "\r\n"):
                self._commit()
            elif part == "\r":
                self.carriage = True
            elif part:
                if self.carriage:  # a progress bar drawing over itself
                    self.live, self.carriage = part, False
                else:
                    self.live += part
        if self.ready:
            self.on_live(self.live)
            self._check_prompt()

    def _commit(self):
        line, self.live, self.carriage = self.live, "", False
        self.line_no += 1
        if self.after_answer:
            self.after_answer = False
            if not line.strip():
                return
        m = MARK.search(line)
        if m:
            before = line[:m.start()]
            if before.strip() and self.ready:
                self._emit(before)
            if m.group(1) == "READY":
                self.ready = True
                self.on_ready()
            else:
                self.finished += 1
                self.on_live("")
                self.on_done(int(m.group(2)))
            return
        if not self.ready:
            return
        if SUDO_MARK in line:
            line = line.replace(SUDO_MARK, "[password]").rstrip() + " ••••••"
        self._emit(line)

    def _emit(self, line):
        self.log.write(line + "\n")
        self.recent = (self.recent + [line])[-40:]
        self.on_line(line)

    def _check_prompt(self):
        live = self.live.rstrip()
        if not live or self.prompted == self.line_no:
            return
        if SUDO_MARK in live:
            kind = "password"
        elif re.search(r"\[R/e/i\]:$", live):
            kind = "failure"
        elif re.search(r"\[(?:Y/n|y/N|Y/N|y/n)\]:?$", live):
            kind = "yesno"
        else:
            # Anything else that stops on a question: give it a moment first
            stamp = self.stall = self.stall + 1
            # (not a path being worked on, like fc-cache's "/usr/share/fonts/TTF:")
            if re.search(r"[:?>]$", live) and not re.fullmatch(r"\s*/\S*:", live):
                GLib.timeout_add(3000, self._stalled, stamp, self.line_no, live)
            return
        self._prompt(kind, live)

    def _stalled(self, stamp, line_no, live):
        if stamp == self.stall and line_no == self.line_no and self.live.rstrip() == live \
                and self.prompted != line_no:
            self._prompt("text", live)
        return False

    def _prompt(self, kind, live):
        self.prompted = self.line_no
        self.on_prompt(kind, live, list(self.recent), self.line_no)


# ── a row of dots that fills up, Nothing's way of showing progress ───────────
class DotProgress(Gtk.DrawingArea):
    def __init__(self, dots=28):
        super().__init__()
        self.dots, self.fraction, self.phase = dots, 0.0, 0.0
        self.set_content_height(16)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)
        self.connect("map", lambda *_: GLib.timeout_add(60, self._tick))

    def set_fraction(self, f):
        self.fraction = max(0.0, min(1.0, f))
        self.queue_draw()

    def _tick(self):
        self.phase += 0.12
        self.queue_draw()
        return self.get_mapped()

    def _draw(self, area, cr, w, h):
        n = self.dots
        gap = w / n
        r = min(h / 2, gap * 0.26)
        fg = self.get_color()
        filled = self.fraction * n
        for i in range(n):
            if i < int(filled):
                cr.set_source_rgba(*RED, 1)
            elif i == int(filled) and self.fraction < 1:
                cr.set_source_rgba(*RED, 0.3 + 0.7 * abs(math.sin(self.phase)))
            else:
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.16)
            cr.arc(gap * (i + 0.5), h / 2, r, 0, 2 * math.pi)
            cr.fill()


CSS = """
:root { --accent-bg-color: #D71921; --accent-fg-color: white; --accent-color: #ff4a52; }
@define-color accent_bg_color #D71921;
@define-color accent_fg_color white;
@define-color accent_color #ff4a52;
.nl-title { font-family: "Doto", "Doto Black", monospace; font-weight: 900; font-size: 42px; letter-spacing: 2px; }
.nl-heading { font-family: "Doto", "Doto Black", monospace; font-weight: 900; font-size: 26px; }
.nl-kicker { font-family: "Doto", "Doto Black", monospace; font-weight: 900; font-size: 13px; letter-spacing: 3px; color: #D71921; }
.nl-lead { font-size: 17px; }
.nl-shot { border-radius: 18px; }
.nl-log { font-family: monospace; font-size: 10.5px; background: transparent; }
.nl-logbox { border-radius: 12px; background: alpha(currentColor, 0.05); padding: 8px; }
.nl-key { font-family: monospace; font-weight: bold; font-size: 12px; padding: 3px 9px; border-radius: 7px;
          background: alpha(currentColor, 0.10); }
.nl-dot { min-width: 14px; min-height: 14px; border-radius: 99px; background: #D71921; }
.nl-num { font-family: "Doto", "Doto Black", monospace; font-weight: 900; font-size: 15px; color: #D71921; min-width: 22px; }
.nl-big { padding: 10px 30px; font-size: 15px; }
.nl-status { min-width: 10px; min-height: 10px; border-radius: 99px; margin: 0 4px; }
.nl-ok { background: alpha(currentColor, 0.85); }
.nl-info { background: transparent; box-shadow: inset 0 0 0 2px alpha(currentColor, 0.6); }
.nl-warn { background: #f5a623; }
.nl-fail { background: #D71921; box-shadow: 0 0 0 3px alpha(#D71921, 0.3); }
"""


def label(text, *classes, wrap=True, xalign=0.0, selectable=False):
    w = Gtk.Label(label=text, wrap=wrap, xalign=xalign, selectable=selectable)
    w.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    if xalign == 0.5:
        w.set_justify(Gtk.Justification.CENTER)
    for c in classes:
        w.add_css_class(c)
    return w


def page(title, child, tag, can_pop=True, header_title=True, header_end=None, closable=True):
    toolbar = Adw.ToolbarView()
    header = Adw.HeaderBar()
    header.set_show_title(header_title)
    header.set_show_end_title_buttons(closable)  # not in a kiosk: closing it there leaves a bare console
    if header_end:
        header.pack_end(header_end())  # a fresh widget per page: one can't sit in two headers
    toolbar.add_top_bar(header)
    scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
    clamp = Adw.Clamp(maximum_size=660, tightening_threshold=520)
    clamp.set_child(child)
    scroller.set_child(clamp)
    toolbar.set_content(scroller)
    p = Adw.NavigationPage(title=title, tag=tag, child=toolbar)
    p.set_can_pop(can_pop)
    return p


def column(spacing=18):
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)
    for m in ("top", "bottom"):
        getattr(box, f"set_margin_{m}")(24)
    box.set_margin_start(18)
    box.set_margin_end(18)
    return box


def status_dot(level):
    """A small dot: Nothing's way of saying ok / note / careful / no. Drawn, not an
    icon, so it looks the same whatever icon theme the computer has."""
    dot = Gtk.Box(valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
    dot.add_css_class("nl-status")
    dot.add_css_class(f"nl-{level}")
    return dot


def big_button(text, style="suggested-action"):
    b = Gtk.Button(label=text, halign=Gtk.Align.CENTER)
    for c in ("pill", "nl-big", style):
        b.add_css_class(c)
    return b

# ── the log and the questions, for a window that runs a Runner ───────────────
class RunnerUI:
    """Mixed into a window that runs its steps in a Runner (self.runner): the
    details log (make_log) and the dialogs for what the steps ask."""
    dialog = None
    token = None
    pending_live = None
    demo = False
    log_path = None

    def make_log(self, height=260):
        self.logview = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                                    wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.logview.add_css_class("nl-log")
        self.buffer = self.logview.get_buffer()
        self.live_mark = self.buffer.create_mark("live", self.buffer.get_end_iter(), True)
        self.log_scroll = Gtk.ScrolledWindow(min_content_height=height, vexpand=True)
        self.log_scroll.set_child(self.logview)
        self.log_scroll.add_css_class("nl-logbox")
        expander = Gtk.Expander(label="Show details")
        expander.set_child(self.log_scroll)
        # Opened: at the latest lines (it follows them from there)
        expander.connect("notify::expanded", lambda e, _: e.get_expanded() and GLib.idle_add(
            lambda: self.logview.scroll_to_mark(self.live_mark, 0, False, 0, 1) and False))
        return expander

    def on_line(self, line):
        self.drop_guessed()
        end = self.buffer.get_end_iter()
        self.buffer.delete(self.buffer.get_iter_at_mark(self.live_mark), end)
        self.buffer.insert(self.buffer.get_end_iter(), line + "\n")
        self.buffer.move_mark(self.live_mark, self.buffer.get_end_iter())
        lines = self.buffer.get_line_count()
        if lines > 6000:
            self.buffer.delete(self.buffer.get_start_iter(), self.buffer.get_iter_at_line(lines - 5000)[1])
        self.scroll_log()

    def on_live(self, text):
        if text.rstrip() != getattr(self, "guessed", None):
            self.drop_guessed()
        # Throttled: progress bars redraw many times a second
        first = self.pending_live is None
        self.pending_live = text
        if first:
            GLib.timeout_add(100, self.flush_live)

    def flush_live(self):
        text, self.pending_live = self.pending_live, None
        if text is None:
            return False
        self.buffer.delete(self.buffer.get_iter_at_mark(self.live_mark), self.buffer.get_end_iter())
        self.buffer.insert(self.buffer.get_end_iter(), text.replace(SUDO_MARK, "[password]"))
        self.scroll_log()
        return False

    def scroll_log(self):
        adj = self.log_scroll.get_vadjustment()
        if adj.get_upper() - adj.get_page_size() - adj.get_value() < 80:
            GLib.idle_add(lambda: self.logview.scroll_to_mark(self.live_mark, 0, False, 0, 1) and False)

    # ── questions from the terminal ──
    def on_prompt(self, kind, text, recent, token):
        self.token = token
        self.guessed = text.rstrip() if kind == "text" else None
        question = re.sub(r"^\s*(::|==>|->)\s*", "", text).strip()
        if kind == "password":
            self.ask_password(any("Sorry, try again" in line for line in recent[-3:]))
        elif kind == "yesno":
            if re.search(r"Proceed with (installation|download)\?", text):
                self.runner.answer("y", token)  # what you agreed to on the last page
                return
            default_yes = "[Y/" in text
            body = re.sub(r"\s*\[[YyNn]/[YyNn]\]:?$", "", question)
            self.ask("The package manager is asking", body + "\n\nIf you're not sure, the highlighted answer is "
                     "its own suggestion.", [("n", "No"), ("y", "Yes")], "y" if default_yes else "n")
        elif kind == "failure":
            tail = "\n".join(line for line in recent[-12:] if line.strip())
            self.ask("A command didn't work", "Often it's a download that broke off: trying again usually works. "
                     "Skipping it can leave part of the desktop not working.",
                     [("e", "Stop"), ("i", "Skip it"), ("r", "Try again")], "r", detail=tail,
                     appearance={"i": Adw.ResponseAppearance.DESTRUCTIVE})
        else:
            self.ask_text(question)

    def reply(self, text, secret=False):
        self.dialog = None
        if self.runner:
            self.runner.answer(text, self.token, secret)

    def show_dialog(self, dialog):
        self.drop_dialog()
        self.dialog = dialog
        dialog.present(self)

    def drop_guessed(self):
        # Output went on after a line that only looked like a question: it wasn't one
        if getattr(self, "guessed", None) is not None:
            self.guessed = None
            self.drop_dialog()

    def drop_dialog(self):
        # The question it answered is gone (the step ended): don't leave it up
        if self.dialog:
            dialog, self.dialog = self.dialog, None
            dialog.force_close()

    def ask(self, heading, body, responses, default, detail=None, appearance=None):
        dialog = Adw.AlertDialog(heading=heading, body=body)
        for rid, text in responses:
            dialog.add_response(rid, text)
        dialog.set_response_appearance(default, Adw.ResponseAppearance.SUGGESTED)
        for rid, look in (appearance or {}).items():
            dialog.set_response_appearance(rid, look)
        dialog.set_default_response(default)
        dialog.set_close_response(default)
        if detail:
            dialog.set_extra_child(self.detail_box(detail))
        dialog.connect("response", lambda d, rid: self.dialog is d and self.reply(rid))
        self.show_dialog(dialog)

    def detail_box(self, text):
        view = label(text, "nl-log", selectable=True)
        sc = Gtk.ScrolledWindow(min_content_height=120, max_content_height=220, propagate_natural_height=True)
        sc.set_child(view)
        sc.add_css_class("nl-logbox")
        return sc

    def ask_password(self, retry):
        body = ("That password didn't work. Try again: it's the one you use to log in to this computer."
                if retry else "To install system parts, the installer needs the password you use to log in "
                "to this computer. It goes to the system (sudo) and nowhere else.")
        if self.demo:
            body += "\n\n(Demo: type anything.)"
        dialog = Adw.AlertDialog(heading="Your password", body=body)
        entry = Gtk.PasswordEntry(show_peek_icon=True, activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("ok", "Continue")
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.set_close_response("cancel")

        def response(d, rid):
            if self.dialog is not d:
                return
            if rid == "ok":
                self.reply(entry.get_text(), secret=True)
            else:
                self.dialog = None
                if self.runner:
                    self.runner.interrupt()
            entry.set_text("")
        dialog.connect("response", response)
        self.show_dialog(dialog)
        entry.grab_focus()

    def ask_text(self, question):
        dialog = Adw.AlertDialog(heading="A question from the installer",
                                 body=question + "\n\nLeave it empty to take its default answer.")
        entry = Gtk.Entry(activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("ok", "Answer")
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.set_close_response("ok")
        dialog.connect("response", lambda d, rid: self.dialog is d and self.reply(entry.get_text()))
        self.show_dialog(dialog)
        entry.grab_focus()

    def open_log(self):
        if self.log_path and self.log_path.exists():
            Gtk.FileLauncher.new(Gio.File.new_for_path(str(self.log_path))).launch(self, None, None)


def load_css():
    css = Gtk.CssProvider()
    css.load_from_string(CSS)
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                              Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
