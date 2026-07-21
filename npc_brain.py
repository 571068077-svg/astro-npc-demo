"""npc_brain.py —— AI-NPC 决策层（意图层）

职责：加载配置 → 拼 prompt（注入记忆+世界状态，但【不给动作列表】）→ 调 DeepSeek → 返回决策文本。
LLM 在这里自由生成 intent.raw_action，落地由 validator.py（能力层）完成。
只用 Python 标准库，无第三方依赖。
"""
import os
import json
import time
import urllib.request
import urllib.error

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DESIGN_MARKER = "===DESIGN_NOTES==="


def load_config():
    """从 .env 读配置（不依赖 python-dotenv）。"""
    cfg = {
        "DEEPSEEK_API_KEY": "",
        "DEEPSEEK_BASE_URL": "https://api.deepseek.com",
        "DEEPSEEK_MODEL": "deepseek-chat",
        "NPC_TEMPERATURE": "0.8",
        "DEEPSEEK_PRICE_INPUT": "",
        "DEEPSEEK_PRICE_OUTPUT": "",
    }
    env_path = os.path.join(BASE_DIR, ".env")
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


def load_system_prompt(prompt_file):
    """读取人设文件，剥离 ===DESIGN_NOTES=== 之后的作者注解，只把人设发给模型。"""
    with open(os.path.join(BASE_DIR, prompt_file), "r", encoding="utf-8") as f:
        text = f.read()
    return text.split(DESIGN_MARKER)[0].strip()


def build_user_prompt(npc, world_state, player_action, event=None):
    """把记忆 + 世界状态 + 玩家行为拼成 user prompt。注意：这里【不注入动作列表】。
    event=游戏层刚发生的结算结果（如交易达成/背叛得手），让 NPC 基于真实结果反应。"""
    mem = npc["memory"]
    inv = ", ".join(f"{k}x{v}" for k, v in npc.get("inventory", {}).items()) or "（几乎一无所有）"
    player_inv = ", ".join(f"{k}x{v}" for k, v in world_state.get("player_inventory", {}).items()) or "（看不清）"
    history = "；".join(mem.get("trade_history", [])) or "（无）"
    lines = [
        "【当前处境】",
        f"- 地点：{world_state.get('location', '荒野营地')}",
        f"- 你现在手上的物资：{inv}",
        f"- 你看到玩家携带：{player_inv}",
        f"- 你对玩家的信任值 trust = {mem.get('trust', 0)}",
        f"- 你当前急需：{', '.join(mem.get('needs', [])) or '（暂无）'}",
        f"- 交易历史：{history}",
        f"- 玩家爽约次数：{mem.get('player_broke_promise', 0)}",
    ]
    if world_state.get("conflict_mode"):
        lines.append("- ⚠ 你正与玩家处于敌对/对峙状态：已经和他翻过脸，不再信任他，不会再跟他做交易")
    if event:
        lines.append(f"- 【刚刚发生】{event}")
    lines += [
        "",
        f"【玩家刚刚】{player_action}",
        "",
        "请以你自己的身份，基于以上处境自主决定这一步做什么。严格按系统要求的 JSON 输出，只输出 JSON。",
    ]
    return "\n".join(lines)


def call_deepseek(cfg, messages, temperature=None):
    """调用 DeepSeek /chat/completions（OpenAI 兼容）。返回 content/usage/latency_ms/error。"""
    url = cfg["DEEPSEEK_BASE_URL"].rstrip("/") + "/chat/completions"
    body = {
        "model": cfg["DEEPSEEK_MODEL"],
        "messages": messages,
        "temperature": float(cfg["NPC_TEMPERATURE"]) if temperature is None else temperature,
        "response_format": {"type": "json_object"},
        "stream": False,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + cfg["DEEPSEEK_API_KEY"],
        },
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
        latency = (time.perf_counter() - t0) * 1000
        return {
            "content": raw["choices"][0]["message"]["content"],
            "usage": raw.get("usage", {}),
            "latency_ms": latency,
            "error": None,
        }
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")
        return {"content": None, "usage": {}, "latency_ms": (time.perf_counter() - t0) * 1000,
                "error": f"HTTP {e.code}: {detail[:300]}"}
    except Exception as e:
        return {"content": None, "usage": {}, "latency_ms": (time.perf_counter() - t0) * 1000,
                "error": f"{type(e).__name__}: {e}"}


def decide(cfg, npc, world_state, player_action, history=None, event=None):
    """完整一轮意图层决策。history=之前的对话轮次（含 NPC 上一轮的 JSON 回复），
    用来治「失忆」；event=游戏层刚结算的结果，让 NPC 基于真实结果反应。返回 call_deepseek 的结果 dict。"""
    messages = [{"role": "system", "content": load_system_prompt(npc["prompt_file"])}]
    if history:
        messages.extend(history[-8:])  # 最近约4轮对话，控制 token 与成本
    messages.append({"role": "user", "content": build_user_prompt(npc, world_state, player_action, event)})
    return call_deepseek(cfg, messages)
