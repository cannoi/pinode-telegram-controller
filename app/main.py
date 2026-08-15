import json, os, socket, threading, time, logging
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import requests

TZ=os.getenv("TZ","Asia/Ho_Chi_Minh")
DATA=Path(os.getenv("DATA_DIR","/data")); DATA.mkdir(parents=True,exist_ok=True)
LOG=Path(os.getenv("LOG_DIR","/data/logs")); LOG.mkdir(parents=True,exist_ok=True)
STATE=Path(os.getenv("STATE_DIR","/data/state")); STATE.mkdir(parents=True,exist_ok=True)
HISTORY=Path(os.getenv("HISTORY_FILE",str(DATA/"node_history.json")))
TOKEN=os.getenv("TELEGRAM_BOT_TOKEN","").strip(); CHAT=os.getenv("TELEGRAM_CHAT_ID","").strip()
HOST=os.getenv("PI_NODE_HOST","host.docker.internal")
PORTS=[int(x.strip()) for x in os.getenv("PI_NODE_PORTS","31401,31402,31403").split(",") if x.strip().isdigit()]
AI=os.getenv("AI_PROVIDER","gemini").lower(); GEMINI=os.getenv("GEMINI_API_KEY","").strip()
SCHED=os.getenv("SCHEDULER_ENABLED","true").lower()=="true"
INTERVAL=max(1,int(os.getenv("MONITOR_INTERVAL_MINUTES","60")))
RESCAN=max(1,int(os.getenv("PROBLEM_RESCAN_MINUTES","10")))
RAM=int(os.getenv("RAM_ALERT","88")); CPU=int(os.getenv("CPU_ALERT","90")); TEMP=int(os.getenv("TEMP_ALERT","78"))
logging.basicConfig(level=logging.INFO,format="%(asctime)s %(levelname)s %(message)s",handlers=[logging.FileHandler(LOG/"controller.log"),logging.StreamHandler()])

def now(): return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def check_ports():
    result=[]
    for p in PORTS:
        ok=False
        try:
            with socket.create_connection((HOST,p),timeout=2): ok=True
        except Exception: pass
        result.append({"port":p,"open":ok})
    return result

def snapshot():
    ports=check_ports(); open_count=sum(x["open"] for x in ports)
    item={"time":now(),"host":HOST,"ports":ports,"open_ports":open_count,"total_ports":len(ports)}
    try:
        data=json.loads(HISTORY.read_text()) if HISTORY.exists() else []
        if not isinstance(data,list): data=[]
    except Exception: data=[]
    data.append(item); HISTORY.write_text(json.dumps(data[-744:],ensure_ascii=False,indent=2))
    return item

def format_status(s):
    lines=["🟢 PI NODE CONTROLLER PRO","━━━━━━━━━━━━━━","🕐 "+s["time"],f"🌐 Host: {s['host']}"]
    for x in s["ports"]: lines.append(("🟢" if x["open"] else "🔴")+f" Port {x['port']}: "+("OPEN" if x["open"] else "CLOSED"))
    lines += ["",f"Kết nối: {s['open_ports']}/{s['total_ports']}"]
    if s["open_ports"]==s["total_ports"]: lines.append("✅ Các port đang phản hồi.")
    else: lines.append("⚠️ Có port không phản hồi. Hãy kiểm tra Pi Node/network.")
    return "\n".join(lines)

def telegram(method,payload=None):
    if not TOKEN: return None
    r=requests.post(f"https://api.telegram.org/bot{TOKEN}/{method}",json=payload or {},timeout=35)
    r.raise_for_status(); return r.json()

def send(text):
    if CHAT: telegram("sendMessage",{"chat_id":CHAT,"text":text})

def gemini(prompt):
    if AI!="gemini" or not GEMINI: return None
    url="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key="+GEMINI
    body={"contents":[{"parts":[{"text":prompt}]}]}
    try:
        r=requests.post(url,json=body,timeout=45); r.raise_for_status(); d=r.json()
        return d["candidates"][0]["content"]["parts"][0]["text"].strip()
    except Exception as e:
        logging.warning("Gemini error: %s",e); return None

def help_text():
    return """🤖 Pi Node Telegram Controller PRO

/status — trạng thái Node
/monitor — kiểm tra ngay
/report — báo cáo ngắn
/diagnostic — chẩn đoán kết nối
/scheduler — trạng thái lịch
/help — danh sách lệnh

Bạn cũng có thể hỏi tự nhiên, ví dụ:
“Node của tôi thế nào?”
“Kiểm tra port Pi Node”"""

def handle(text):
    t=text.strip(); low=t.lower()
    if low in ("/start","/help"): return help_text()
    if low in ("/status","/monitor","/report","/diagnostic"): return format_status(snapshot())
    if low.startswith("/scheduler"):
        return f"⏱ Scheduler: {'BẬT' if SCHED else 'TẮT'}\nChu kỳ: {INTERVAL} phút\nKhi lỗi: kiểm tra lại {RESCAN} phút."
    if low.startswith("/ping"): return "🟢 Controller đang hoạt động."
    s=snapshot()
    answer=gemini(f"Bạn là trợ lý Pi Node. Trả lời tiếng Việt ngắn gọn, không bịa dữ liệu. Dữ liệu hiện tại: {json.dumps(s,ensure_ascii=False)}\nCâu hỏi người dùng: {t}")
    return answer or format_status(s)

def polling():
    if not TOKEN:
        logging.error("TELEGRAM_BOT_TOKEN is missing")
        return
    offset=0
    while True:
        try:
            data=telegram("getUpdates",{"timeout":25,"offset":offset}) or {}
            for u in data.get("result",[]):
                offset=u["update_id"]+1
                msg=u.get("message",{}); text=msg.get("text","")
                if not text: continue
                cid=str(msg.get("chat",{}).get("id",""))
                if CHAT and cid!=CHAT: continue
                try: telegram("sendChatAction",{"chat_id":cid,"action":"typing"}); telegram("sendMessage",{"chat_id":cid,"text":handle(text)})
                except Exception as e: logging.warning("message error: %s",e)
        except Exception as e:
            logging.warning("Telegram polling: %s",e); time.sleep(5)

def scheduler():
    if not SCHED: return
    while True:
        try:
            s=snapshot()
            if CHAT and s["open_ports"]<s["total_ports"]: send("🚨 CANH BÁO NODE\n\n"+format_status(s))
        except Exception as e: logging.warning("scheduler: %s",e)
        time.sleep(INTERVAL*60)

class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path!="/health": self.send_response(404); self.end_headers(); return
        body=b'{"status":"ok","service":"pinode-telegram-controller"}'
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass

def main():
    threading.Thread(target=lambda: HTTPServer(("0.0.0.0",8787),Health).serve_forever(),daemon=True).start()
    threading.Thread(target=polling,daemon=True).start()
    threading.Thread(target=scheduler,daemon=True).start()
    logging.info("Pi Node Telegram Controller PRO started")
    while True: time.sleep(3600)

if __name__=="__main__": main()
