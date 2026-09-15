#!/usr/bin/env python3
"""
QuantAgent Pro - Minimal UI (Estilo GitHub Copilot Chat)
"""

import os
import re
import json
import difflib
import asyncio
import subprocess
import hashlib
from pathlib import Path
from typing import Any, Optional, Dict, List, Tuple

from dotenv import load_dotenv
import litellm

from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, Vertical, ScrollableContainer
from textual.css.query import NoMatches
from textual.reactive import reactive
from textual.widgets import (
    Button, Input, Label, Markdown, Static, TextArea
)
from textual.screen import ModalScreen

load_dotenv()

# ─────────────────────────────────────────────────────────────────────────────
# GROQ API KEY — definida via .env ou variável de ambiente
# ─────────────────────────────────────────────────────────────────────────────
if not os.environ.get("GROQ_API_KEY"):
    print("AVISO: GROQ_API_KEY não definida. Defina no .env ou exporte a variável.")

CONFIG_PATH = Path(__file__).parent / "config.json"
CACHE_PATH = Path(__file__).parent / ".cache"
CACHE_PATH.mkdir(exist_ok=True)

config: dict = {}
if CONFIG_PATH.exists():
    try:
        config = json.loads(CONFIG_PATH.read_text())
        if "api_key" in config and "provider" in config:
            os.environ[f"{config['provider'].upper()}_API_KEY"] = config["api_key"]
    except Exception:
        pass

MODELS = [
    "groq/llama-3.3-70b-versatile",
    "groq/llama-3.1-8b-instant",
    "openai/gpt-4o",
    "deepseek/deepseek-chat",
]

IGNORED_DIRS = {".git", "venv", "__pycache__", "node_modules", ".idea", ".vscode", "dist", "build", ".next", ".cache"}
SUPPORTED_EXT = {".py", ".js", ".ts", ".cpp", ".c", ".h", ".json", ".yaml", ".yml", ".toml", ".md", ".sh", ".bat", ".env", ".rs", ".go", ".java"}

# ─────────────────────────────────────────────────────────────────────────────
# Tools
# ─────────────────────────────────────────────────────────────────────────────

class ToolResult:
    def __init__(self, ok: bool, output: str, error: str = ""):
        self.ok = ok
        self.output = output
        self.error = error
    def to_str(self) -> str:
        return self.output if self.ok else f"[ERRO] {self.error}"

def _resolve(path: str, root: Optional[str]) -> Path:
    p = Path(path)
    if not p.is_absolute() and root:
        return Path(root) / p
    return p

def tool_read_file(path: str, root: Optional[str]) -> ToolResult:
    try:
        p = _resolve(path, root)
        if not p.exists():
            return ToolResult(False, "", f"Não encontrado: {p}")
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        numbered = "\n".join(f"{i+1:4d} | {line}" for i, line in enumerate(lines))
        return ToolResult(True, numbered)
    except Exception as e:
        return ToolResult(False, "", str(e))

def tool_write_file(path: str, content: str, root: Optional[str]) -> ToolResult:
    try:
        p = _resolve(path, root)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        return ToolResult(True, f"✅ Salvo: {p}")
    except Exception as e:
        return ToolResult(False, "", str(e))

def tool_list_dir(path: str, root: Optional[str], max_depth: int = 3) -> ToolResult:
    try:
        p = _resolve(path, root)
        if not p.is_dir():
            return ToolResult(False, "", f"Não é diretório: {p}")
        lines = []
        def walk(curr: Path, depth: int):
            if depth > max_depth:
                return
            try:
                for child in sorted(curr.iterdir()):
                    if child.name.startswith(".") or child.name in IGNORED_DIRS:
                        continue
                    prefix = "  " * depth
                    icon = "📁 " if child.is_dir() else "📄 "
                    lines.append(f"{prefix}{icon}{child.name}")
                    if child.is_dir():
                        walk(child, depth + 1)
            except PermissionError:
                pass
        walk(p, 0)
        return ToolResult(True, "\n".join(lines) or "(vazio)")
    except Exception as e:
        return ToolResult(False, "", str(e))

def tool_grep(pattern: str, path: str, root: Optional[str], context: int = 3) -> ToolResult:
    try:
        base = _resolve(path, root)
        results = []
        searched = 0
        for fpath in base.rglob("*"):
            if fpath.is_dir() or fpath.suffix not in SUPPORTED_EXT:
                continue
            if any(part in IGNORED_DIRS for part in fpath.parts):
                continue
            try:
                lines = fpath.read_text(encoding="utf-8", errors="replace").splitlines()
                searched += 1
                matches = []
                for i, line in enumerate(lines):
                    if re.search(pattern, line, re.IGNORECASE):
                        start = max(0, i - context)
                        end = min(len(lines), i + context + 1)
                        matches.append((i + 1, start, end, lines[start:end]))
                if matches:
                    rel = fpath.relative_to(base) if base in fpath.parents else fpath
                    results.append(f"\n📄 {rel}")
                    for lineno, start, end, ctx_lines in matches:
                        results.append(f"  → linha {lineno}:")
                        for j, ctx_line in enumerate(ctx_lines):
                            abs_line = start + j + 1
                            marker = ">>>" if abs_line == lineno else "   "
                            results.append(f"     {marker} {abs_line:4d} | {ctx_line}")
            except Exception:
                continue
        if not results:
            return ToolResult(True, f"Nenhum resultado para '{pattern}' em {searched} arquivo(s).")
        header = f"🔍 '{pattern}' em {searched} arquivos:\n"
        return ToolResult(True, header + "\n".join(results))
    except Exception as e:
        return ToolResult(False, "", str(e))

def tool_run_command(command: str, root: Optional[str], timeout: int = 30) -> ToolResult:
    try:
        r = subprocess.run(command, shell=True, cwd=root or str(Path.cwd()), capture_output=True, text=True, timeout=timeout)
        output = r.stdout + r.stderr
        return ToolResult(r.returncode == 0, output or "(sem output)", "" if r.returncode == 0 else f"Exit {r.returncode}")
    except subprocess.TimeoutExpired:
        return ToolResult(False, "", "Timeout")
    except Exception as e:
        return ToolResult(False, "", str(e))

def compute_diff(original: str, new_content: str, filename: str = "") -> str:
    orig_lines = original.splitlines(keepends=True)
    new_lines = new_content.splitlines(keepends=True)
    diff = difflib.unified_diff(orig_lines, new_lines, fromfile=f"a/{filename}", tofile=f"b/{filename}", n=3)
    return "".join(diff)

# ─────────────────────────────────────────────────────────────────────────────
# LLM Config
# ─────────────────────────────────────────────────────────────────────────────

TOOL_DEFINITIONS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Lê arquivo.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Escreve arquivo.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "Lista pastas.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "default": "."}}
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "grep",
            "description": "Busca regex.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string"},
                    "path": {"type": "string", "default": "."}
                },
                "required": ["pattern"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Roda comando shell.",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"]
            }
        }
    }
]

SYSTEM_BASE = """Você é o QuantAgent Pro. Pasta raiz: {root}
Regras: 1. Use list_directory('.') para entender o projeto. 2. Use read_file antes de escrever. 3. Forneça código COMPLETO."""

# ─────────────────────────────────────────────────────────────────────────────
# Modals
# ─────────────────────────────────────────────────────────────────────────────

class ConfirmWriteScreen(ModalScreen):
    BINDINGS = [
        Binding("y", "confirm", "Salvar", show=True),
        Binding("n", "cancel", "Cancelar", show=True)
    ]

    def __init__(self, path: str, diff: str, **kwargs):
        super().__init__(**kwargs)
        self.path = path
        self.diff = diff

    def compose(self) -> ComposeResult:
        with Container(id="confirm-modal"):
            yield Static(f"[bold]💾 Salvar: {self.path}[/bold]")
            lines = []
            for l in self.diff.splitlines()[:50]:
                if l.startswith("+") and not l.startswith("+++"):
                    lines.append(f"[green]{l}[/green]")
                elif l.startswith("-") and not l.startswith("---"):
                    lines.append(f"[red]{l}[/red]")
                else:
                    lines.append(l)
            yield Static("\n".join(lines), id="diff-view")
            with Horizontal():
                yield Button("Yes (Y)", variant="success", id="btn-confirm")
                yield Button("No (N)", variant="error", id="btn-cancel")

    def action_confirm(self):
        self.dismiss(True)

    def action_cancel(self):
        self.dismiss(False)

    @on(Button.Pressed, "#btn-confirm")
    def on_yes(self):
        self.dismiss(True)

    @on(Button.Pressed, "#btn-cancel")
    def on_no(self):
        self.dismiss(False)

class ChatMessage(Static):
    def __init__(self, role: str, content: str, **kwargs):
        super().__init__(**kwargs)
        self.role = role
        self.msg_content = content

    def compose(self) -> ComposeResult:
        if self.role == "user":
            yield Static(self.msg_content, classes="msg-user")
        elif self.role == "tool_result":
            txt = self.msg_content
            if len(txt) > 300:
                txt = txt[:300] + "..."
            yield Static(f"⚙ {txt}", classes="msg-tool")
        elif self.role == "tool_call":
            yield Static(f"🛠 {self.msg_content}", classes="msg-tool")
        else:
            yield Markdown(self.msg_content, classes="msg-ai")

# ─────────────────────────────────────────────────────────────────────────────
# Main App (Minimalist UI)
# ─────────────────────────────────────────────────────────────────────────────

class QuantAgentProApp(App):
    CSS = """
    Screen {
        background: #1e1e1e;
        layout: vertical;
    }
    
    #top-bar {
        height: 3;
        background: #252526;
        border-bottom: solid #333;
        padding: 0 2;
        align: center middle;
    }
    #session-title {
        color: #cccccc;
        text-style: bold;
    }
    #folder-indicator {
        color: #888888;
        margin-left: 2;
        text-style: italic;
    }

    #chat-scroll {
        height: 1fr;
        padding: 2 4;
        overflow-y: auto;
    }

    ChatMessage {
        margin-bottom: 1;
        width: 100%;
    }
    .msg-user {
        background: #2d2d2d;
        color: #d4d4d4;
        padding: 1 2;
        margin-bottom: 1;
    }
    .msg-ai {
        color: #d4d4d4;
        padding: 0 1;
    }
    .msg-tool {
        color: #569cd6;
        padding: 0 1;
        text-style: dim;
    }
    Markdown {
        background: transparent;
        color: #d4d4d4;
    }

    #input-area {
        dock: bottom;
        height: auto;
        min-height: 8;
        padding: 1 4 2 4;
        background: #1e1e1e;
        border-top: solid #333;
    }

    #chat-input {
        height: 5;
        background: #2d2d2d;
        border: solid #444;
        color: #ffffff;
        padding: 1;
    }
    #chat-input:focus {
        border: solid #007acc;
    }
    TextArea .text-area--cursor {
        background: #007acc;
    }

    #input-actions {
        height: 3;
        margin-top: 1;
        align: left middle;
    }
    
    #btn-context {
        width: 3;
        height: 3;
        background: transparent;
        color: #cccccc;
        border: solid #555;
        margin-right: 1;
    }
    #btn-context:hover {
        background: #333;
    }

    #btn-agent, #btn-auto {
        height: 3;
        padding: 0 2;
        background: transparent;
        color: #888888;
        border: solid #444;
        margin-right: 1;
    }
    
    #btn-agent.active {
        color: #ffffff;
        background: #0e639c;
        border: solid #007acc;
    }
    #btn-auto.active {
        color: #ffffff;
        background: #0e639c;
        border: solid #007acc;
    }

    #spacer {
        width: 1fr;
    }

    #btn-send {
        height: 3;
        width: 10;
        background: #007acc;
        color: #ffffff;
        border: none;
        text-style: bold;
    }
    #btn-send:hover {
        background: #1c97ea;
    }
    #btn-send:disabled {
        background: #333;
        color: #666;
    }

    #status-bar {
        height: 1;
        background: #007acc;
        color: #ffffff;
        padding: 0 2;
        align: left middle;
        dock: bottom;
    }
    #status-left {
        color: #ffffff;
    }
    #status-right {
        color: #ffffff;
    }

    /* Modais */
    #confirm-modal {
        background: #252526;
        border: solid #007acc;
        padding: 2;
        width: 90%;
        height: 80%;
        align: center middle;
    }
    ConfirmWriteScreen {
        align: center middle;
    }
    #diff-view {
        height: 1fr;
        background: #1e1e1e;
        border: solid #444;
        padding: 1;
        overflow-y: scroll;
        color: #d4d4d4;
    }
    Horizontal {
        height: 3;
        margin-top: 1;
    }
    """

    BINDINGS = [
        Binding("ctrl+n", "new_chat", "Nova Sessão"),
        Binding("ctrl+o", "open_folder", "Abrir Pasta"),
        Binding("escape", "cancel_worker", "Cancelar"),
    ]

    current_folder: reactive[str | None] = reactive(None)
    current_mode: reactive[str] = reactive("auto")
    is_thinking: reactive[bool] = reactive(False)

    def __init__(self):
        super().__init__()
        self.messages: list[dict] = []
        self._worker_task: asyncio.Task | None = None
        self._streaming_widget: Static | None = None
        self._waiting_for_folder = False

    def compose(self) -> ComposeResult:
        with Horizontal(id="top-bar"):
            yield Label("◈ New Session", id="session-title")
            yield Static("C:/ALXQuant", id="folder-indicator")
        
        with ScrollableContainer(id="chat-scroll"):
            yield Static("[dim]Describe the outcome you want...[/dim]", id="welcome-msg")

        with Vertical(id="input-area"):
            yield TextArea(id="chat-input")
            with Horizontal(id="input-actions"):
                yield Button("+", id="btn-context")
                yield Button("Agent", id="btn-agent")
                yield Button("Auto", id="btn-auto")
                yield Static("", id="spacer") # Espaço flexível para empurrar o botão
                yield Button("Submit", id="btn-send")

        with Horizontal(id="status-bar"):
            yield Label("Default Approvals", id="status-left")
            yield Static("", id="spacer-status") # Espaço flexível
            yield Label("Worktree main", id="status-right")

    def on_mount(self):
        self.query_one("#chat-input").focus()
        self._detect_root()
        self._update_ui_mode()

    def _detect_root(self):
        check = Path.cwd()
        for _ in range(5):
            if (check / ".git").is_dir() or (check / ".vscode").is_dir():
                self.current_folder = str(check)
                return
            check = check.parent
        self.current_folder = str(Path.cwd())

    def watch_current_folder(self, folder: str | None):
        if folder:
            self.query_one("#folder-indicator").update(str(folder))
            self.query_one("#session-title").update(f"◈ New Session in {Path(folder).name}")

    def watch_is_thinking(self, thinking: bool):
        self.query_one("#btn-send").disabled = thinking

    def watch_current_mode(self, mode: str):
        self._update_ui_mode()

    def _update_ui_mode(self):
        btn_agent = self.query_one("#btn-agent", Button)
        btn_auto = self.query_one("#btn-auto", Button)
        
        btn_agent.remove_class("active")
        btn_auto.remove_class("active")
        
        if self.current_mode == "agent":
            btn_agent.add_class("active")
        else:
            btn_auto.add_class("active")

    def action_open_folder(self):
        self.query_one("#chat-input", TextArea).load_text("")
        self._waiting_for_folder = True
        self.query_one("#welcome-msg").update("[bold cyan]Digite o caminho da pasta do projeto e pressione Enter:[/bold cyan]")

    def action_new_chat(self):
        self.messages.clear()
        scroll = self.query_one("#chat-scroll")
        for child in list(scroll.children):
            child.remove()
        scroll.mount(Static("[dim]Describe the outcome you want...[/dim]", id="welcome-msg"))

    def action_cancel_worker(self):
        if self._worker_task and not self._worker_task.done():
            self._worker_task.cancel()
            self.is_thinking = False

    @on(Button.Pressed, "#btn-send")
    def on_send(self):
        self._do_send()

    @on(Button.Pressed, "#btn-agent")
    def on_sel_agent(self):
        self.current_mode = "agent"

    @on(Button.Pressed, "#btn-auto")
    def on_sel_auto(self):
        self.current_mode = "auto"

    @on(Button.Pressed, "#btn-context")
    def on_add_context(self):
        self.query_one("#chat-input", TextArea).insert("@")
        self.query_one("#chat-input", TextArea).focus()

    def on_key(self, event) -> None:
        chat_input = self.query_one("#chat-input", TextArea)
        if chat_input.has_focus:
            if event.key == "enter" and not event.is_shift:
                event.prevent_default()
                event.stop()
                self._do_send()
                return
            if event.key == "enter" and event.is_shift:
                event.prevent_default()
                event.stop()
                chat_input.insert("\n")
                return

    def _do_send(self):
        inp = self.query_one("#chat-input", TextArea)
        text = inp.text.strip()
        if not text or self.is_thinking:
            return
        inp.load_text("")

        if self._waiting_for_folder:
            if Path(text).is_dir():
                self.current_folder = str(Path(text))
                self._waiting_for_folder = False
                self.query_one("#welcome-msg").update("[dim]Pasta definida. Describe the outcome you want...[/dim]")
            else:
                self.query_one("#welcome-msg").update("[red]Pasta não encontrada. Tente novamente.[/red]")
            return

        self._add_message("user", text)
        self.messages.append({"role": "user", "content": text})
        self.is_thinking = True
        self._worker_task = asyncio.create_task(self._agent_loop())

    async def _agent_loop(self):
        try:
            model = MODELS[0]
            root = self.current_folder
            mode = self.current_mode

            sys_prompt = SYSTEM_BASE.format(root=root or "Nenhuma")
            if root:
                res = tool_list_dir(".", root, max_depth=1)
                if res.ok:
                    sys_prompt += "\nEstrutura:\n" + "\n".join(res.output.splitlines()[:30])
            
            if mode == "agent":
                sys_prompt += "\nMODO AGENTE: Você tem acesso a ferramentas. Execute a tarefa de ponta a ponta, lendo e escrevendo arquivos."
            else:
                sys_prompt += "\nMODO AUTO: Responda diretamente. Use ferramentas APENAS se precisar ler algo para responder."

            trimmed = self.messages[-6:]
            full_messages = [{"role": "system", "content": sys_prompt}] + trimmed
            tools = TOOL_DEFINITIONS if mode == "agent" else None

            self._add_streaming_placeholder()

            while True:
                kwargs = {
                    "model": model,
                    "messages": full_messages,
                    "stream": True,
                    "temperature": 0.15
                }
                if tools:
                    kwargs["tools"] = tools
                
                response = await asyncio.to_thread(litellm.completion, **kwargs)
                full_content = ""
                tool_calls = []

                for chunk in response:
                    if not chunk.choices:
                        continue
                    delta = chunk.choices[0].delta
                    
                    if hasattr(delta, "content") and delta.content:
                        full_content += delta.content
                        self._stream_token(delta.content)
                        
                    if hasattr(delta, "tool_calls") and delta.tool_calls:
                        for tc in delta.tool_calls:
                            idx = getattr(tc, "index", 0)
                            while len(tool_calls) <= idx:
                                tool_calls.append({"id": "", "function": {"name": "", "arguments": ""}})
                            if getattr(tc, "id", None):
                                tool_calls[idx]["id"] = tc.id
                            if getattr(tc.function, "name", None):
                                tool_calls[idx]["function"]["name"] += tc.function.name
                            if getattr(tc.function, "arguments", None):
                                tool_calls[idx]["function"]["arguments"] += tc.function.arguments

                self._finalize_streaming(full_content)

                if tool_calls:
                    full_messages.append({
                        "role": "assistant",
                        "content": full_content or None,
                        "tool_calls": [
                            {"id": t["id"], "type": "function", "function": t["function"]} for t in tool_calls
                        ]
                    })
                    for tc in tool_calls:
                        name = tc["function"]["name"]
                        args_raw = tc["function"].get("arguments", "{}")
                        try:
                            args = json.loads(args_raw)
                        except Exception:
                            args = {}
                        
                        self._add_message("tool_call", f"{name}({json.dumps(args)[:50]})")
                        result = await self._exec_tool(name, args, root)
                        res_text = result.to_str()
                        self._add_message("tool_result", res_text)
                        
                        if len(res_text) > 2000:
                            res_text = res_text[:1000] + "\n...[TRUNCADO]...\n" + res_text[-1000:]
                            
                        full_messages.append({
                            "role": "tool",
                            "tool_call_id": tc["id"],
                            "content": res_text
                        })
                    self._add_streaming_placeholder()
                    continue
                else:
                    if full_content:
                        self.messages.append({"role": "assistant", "content": full_content})
                    break

        except asyncio.CancelledError:
            pass
        except Exception as e:
            self._add_message("tool_result", f"❌ Erro: {e}")
        finally:
            self.is_thinking = False

    async def _exec_tool(self, name: str, args: dict, root: Optional[str]) -> ToolResult:
        if name == "read_file":
            return await asyncio.to_thread(tool_read_file, args.get("path", ""), root)
        elif name == "write_file":
            p = args.get("path", "")
            c = args.get("content", "")
            orig = ""
            if _resolve(p, root).exists():
                orig = _resolve(p, root).read_text(encoding="utf-8", errors="replace")
            if await self.app.push_screen_wait(ConfirmWriteScreen(p, compute_diff(orig, c, p))):
                return await asyncio.to_thread(tool_write_file, p, c, root)
            return ToolResult(False, "", "Cancelado")
        elif name == "list_directory":
            return await asyncio.to_thread(tool_list_dir, args.get("path", "."), root)
        elif name == "grep":
            return await asyncio.to_thread(tool_grep, args.get("pattern", ""), args.get("path", "."), root)
        elif name == "run_command":
            return await asyncio.to_thread(tool_run_command, args.get("command", ""), root)
        return ToolResult(False, "", "Desconhecida")

    def _add_streaming_placeholder(self):
        self._streaming_widget = Static("▌", classes="msg-ai")
        scroll = self.query_one("#chat-scroll")
        scroll.mount(self._streaming_widget)
        scroll.scroll_end(animate=False)

    def _stream_token(self, token: str):
        if self._streaming_widget:
            if not hasattr(self._streaming_widget, "_buf"):
                self._streaming_widget._buf = ""
            self._streaming_widget._buf += token
            self._streaming_widget.update(self._streaming_widget._buf + "▌")
            self.query_one("#chat-scroll").scroll_end(animate=False)

    def _finalize_streaming(self, text: str):
        if self._streaming_widget:
            self._streaming_widget.update(text or "")
            self._streaming_widget = None

    def _add_message(self, role: str, content: str):
        scroll = self.query_one("#chat-scroll")
        try:
            self.query_one("#welcome-msg").remove()
        except NoMatches:
            pass
        scroll.mount(ChatMessage(role, content))
        scroll.scroll_end(animate=False)

if __name__ == "__main__":
    app = QuantAgentProApp()
    app.run()