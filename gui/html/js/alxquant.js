/* ─────────────────────────────────────────────
   ALXQUANT Terminal — Data Layer & UI Logic
   Version: v10.4.0 (Tab-based Architecture)
   ───────────────────────────────────────────── */

const API_BASE = '/api';

/* ── Helpers ── */
function $(sel) { return document.querySelector(sel); }
function $$(sel) { return document.querySelectorAll(sel); }

function fmtNum(n) {
    if (n === null || n === undefined || n === '—') return '—';
    const v = typeof n === 'string' ? parseFloat(n) : n;
    if (isNaN(v)) return '—';
    if (Math.abs(v) >= 1e6) return (v / 1e6).toFixed(1) + 'M';
    if (Math.abs(v) >= 1e3) return (v / 1e3).toFixed(1) + 'K';
    return v.toFixed(2);
}

function fmtPrice(n) {
    if (n === null || n === undefined || n === '—') return '—';
    const v = typeof n === 'string' ? parseFloat(n) : n;
    if (isNaN(v)) return '—';
    return v.toFixed(2);
}

function cls(val) {
    if (val === null || val === undefined) return '';
    const v = typeof val === 'string' ? parseFloat(val) : val;
    if (isNaN(v)) return '';
    return v >= 0 ? 'positive' : 'negative';
}

/* Background-refresh helpers: avoid clearing the DOM on periodic refresh.
   _sigOf computes a stable signature; _changed returns true only when the
   signature differs from the last one stored on the element (so unchanged
   data never triggers a repaint -> no flicker). */
function _sigOf(o) { try { return JSON.stringify(o); } catch (e) { return String(o); } }
function _changed(el, sig) { if (!el) return true; if (el.dataset.sig === sig) return false; el.dataset.sig = sig; return true; }

/* ── Toast ── */
function toast(msg, type) {
    let c = document.querySelector('.toast-container');
    if (!c) { c = document.createElement('div'); c.className = 'toast-container'; document.body.appendChild(c); }
    const t = document.createElement('div'); t.className = 'toast ' + (type || '');
    t.textContent = msg; c.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; t.style.transition = 'opacity 0.5s'; setTimeout(() => t.remove(), 500); }, 4000);
}

/* ── Modals ── */
function toggleHelp() { $('#helpModal').classList.toggle('open'); }
function toggleSettings() {
    const m = $('#settingsModal');
    m.classList.toggle('open');
    if (m.classList.contains('open')) loadSettings();
}
function closeModal(id) { $(`#${id}`).classList.remove('open'); }
document.addEventListener('keydown', e => {
    if (e.key === 'Escape') { $$('.modal-overlay.open').forEach(el => el.classList.remove('open')); }
    if (e.key === 'F5') { e.preventDefault(); loadAll(); toast('Refreshing all data...', 'info'); }
    /* Tab switching: 1-9 */
    if (e.key >= '1' && e.key <= '9' && !e.ctrlKey && !e.metaKey && !e.altKey) {
        const tabs = ['datahouse', 'assetdna', 'regime', 'risksentiment', 'news', 'nlpsentiment', 'dataminer', 'calibration', 'checkfaqs', 'agents'];
        const idx = parseInt(e.key) - 1;
        if (tabs[idx]) switchTab(tabs[idx]);
    }
});

/* ── Clock ── */
function updateClock() {
    const d = new Date();
    const s = d.toISOString().slice(0,19).replace('T',' ') + ' UTC';
    $('#headerDatetime').textContent = s;
}
setInterval(updateClock, 1000);

/* ── API Calls ── */
async function api(path, timeoutMs = 120000, method = 'GET', body = null) {
    try {
        const opts = { signal: AbortSignal.timeout(timeoutMs) };
        if (method && method !== 'GET') {
            opts.method = method;
            if (body !== null) {
                opts.headers = { 'Content-Type': 'application/json' };
                opts.body = JSON.stringify(body);
            }
        }
        const r = await fetch(API_BASE + path, opts);
        if (!r.ok) { throw new Error(r.status + ' ' + r.statusText); }
        return await r.json();
    } catch(e) {
        console.warn('API error', path, e);
        return null;
    }
}

/* ══════════════════════════════════════════════════
   TAB SYSTEM
   ══════════════════════════════════════════════════ */
let currentTab = localStorage.getItem('alxquant_tab') || 'datahouse';
const tabLoaded = {};

function switchTab(tabName) {
    /* Update button state */
    $$('.tab-btn').forEach(b => b.classList.remove('active'));
    const btn = $(`.tab-btn[data-tab="${tabName}"]`);
    if (btn) btn.classList.add('active');

    /* Update content */
    $$('.tab-content').forEach(c => c.classList.remove('active'));
    const contentMap = {
        datahouse: '#tabDatahouse',
        assetdna: '#tabAssetDna',
        regime: '#tabRegime',
        risksentiment: '#tabRiskSentiment',
        nlpsentiment: '#tabNlpSentiment',
        dataminer: '#tabDataMiner',
        calibration: '#tabCalibration',
        checkfaqs: '#tabCheckfaqs',
        news: '#tabNews',
        agents: '#tabAgents'
    };
    const el = $(contentMap[tabName]);
    if (el) el.classList.add('active');

    currentTab = tabName;
    localStorage.setItem('alxquant_tab', tabName);

    /* Load data on first activation */
    if (!tabLoaded[tabName]) {
        loadTabData(tabName);
        tabLoaded[tabName] = true;
    }

    /* Re-render filtered log for this tab */
    if (tabName === 'assetdna') {
        _dnaLogReady = false;
        const logBody = $('#dnaLogBody');
        if (logBody) { logBody.innerHTML = ''; _dnaLogReady = true; }
    }
    renderActiveTabLog();
}

function loadTabData(tabName) {
    switch (tabName) {
        case 'datahouse': loadDatahouse(); break;
        case 'assetdna': loadAssetDnaTab(); break;
        case 'regime': loadRegimeTab(); break;
        case 'risksentiment': loadRiskSentimentTab(); break;
        case 'nlpsentiment': loadNlpSentimentTab(); break;
        case 'dataminer': loadDataMinerTab(); break;
        case 'calibration': loadCalibrationTab(); break;
        case 'checkfaqs': loadCheckfaqsTab(); break;
        case 'news': loadNewsTab(); break;
        case 'agents': loadAgentsTab(); break;
    }
}

/* ── Check FAQs (mesas proprietárias) ── */
async function loadCheckfaqsTab() {
    const c = $('#tabCheckfaqs');
    if (!c) return;
    c.innerHTML = `
        <div class="panel-header" style="justify-content:space-between">
            <span>CHECK FAQs — Mesas Proprietárias</span>
            <span>
                <button class="tf-btn active" onclick="runCheckfaqsScan()">RUN SCAN</button>
                <span id="cfScanStatus" style="color:#888;font-size:11px;margin-left:8px"></span>
            </span>
        </div>
        <div class="cf-add" style="display:flex;gap:8px;align-items:center;padding:8px 10px;border-bottom:1px solid #333;flex-wrap:wrap">
            <input id="cfNewName" placeholder="Nome da mesa (ex: FTMO)" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:5px 8px;font-size:12px;min-width:160px">
            <input id="cfNewHome" placeholder="URL (https://...)" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:5px 8px;font-size:12px;flex:1;min-width:220px">
            <button class="tf-btn" onclick="addCheckfaqsFirm()">ADICIONAR MESA</button>
        </div>
        <div class="panel-content" style="overflow:auto">
            <table class="watchlist-table" id="cfTable">
                <thead><tr><th>MESA</th><th>HOMEPAGE</th><th>FAQ</th><th>PRICING</th><th>ÚLT. VERIF.</th><th>ÚLT. MUDANÇA</th><th>STATUS</th><th></th></tr></thead>
                <tbody></tbody>
            </table>
        </div>`;
    await refreshCheckfaqs();
}

async function addCheckfaqsFirm() {
    const name = ($('#cfNewName').value || '').trim();
    const home = ($('#cfNewHome').value || '').trim();
    if (!name || !home) { toast('Informe nome e URL', 'error'); return; }
    const res = await api('/checkfaqs/add', 30000, 'POST', { name, home });
    if (res && res.ok) {
        toast('Mesa adicionada: ' + name + ' (clique RUN SCAN para varrer)', 'info');
        $('#cfNewName').value = '';
        $('#cfNewHome').value = '';
        await refreshCheckfaqs();
    } else {
        toast('Erro: ' + (res ? res.message : 'falha'), 'error');
    }
}

async function deleteCheckfaqsFirm(name) {
    if (!name) return;
    const res = await api('/checkfaqs/firm', 30000, 'DELETE', { name });
    if (res && res.ok) {
        toast('Mesa removida: ' + name, 'info');
        await refreshCheckfaqs();
    } else {
        toast('Erro: ' + (res ? res.message : 'falha'), 'error');
    }
}

async function refreshCheckfaqs() {
    const data = await api('/checkfaqs');
    if (!data) return;
    const statusEl = $('#cfScanStatus');
    if (statusEl) statusEl.textContent = data.scanning ? 'scanning…' : '';
    const tbody = $('#cfTable tbody');
    if (!tbody) return;
    tbody.innerHTML = '';
    (data.firms || []).forEach(firm => {
        const pages = firm.pages || [];
        const has = (t) => pages.some(p => p.type === t);
        const cnt = (t) => pages.filter(p => p.type === t).length;
        const latest = (field) => pages.reduce((m, p) => {
            const v = p[field];
            return (v && v > m) ? v : m;
        }, '');
        const fmt = (v) => v ? v.replace('T', ' ').slice(0, 19) : '—';
        const tr = document.createElement('tr');
        if (firm.any_changed) { tr.className = 'changed'; tr.style.cursor = 'pointer'; }
        const firstKey = (pages.find(p => p.changed) || pages[0] || {}).key;
        tr.innerHTML =
            '<td>' + firm.name + '</td>' +
            '<td>' + (has('homepage') ? '✓' : '—') + '</td>' +
            '<td>' + (cnt('faq') ? '✓' + (cnt('faq') > 1 ? ' ×' + cnt('faq') : '') : '—') + '</td>' +
            '<td>' + (has('pricing') ? '✓' : '—') + '</td>' +
            '<td>' + fmt(latest('last_checked')) + '</td>' +
            '<td>' + fmt(latest('last_changed')) + '</td>' +
            '<td>' + (firm.any_changed ? '<span style="color:#ff6b6b">MUDOU</span>' : '<span style="color:#5fbf6f">ok</span>') + '</td>' +
            '<td style="text-align:center"><button class="cf-del" title="Remover mesa" onclick="deleteCheckfaqsFirm(\'' + firm.name.replace(/'/g, "\\'") + '\')">✕</button></td>';
        if (firm.any_changed && firstKey) tr.onclick = () => openCheckfaqsDiff(firm.name, firstKey);
        tbody.appendChild(tr);
    });
}

async function runCheckfaqsScan() {
    const res = await api('/checkfaqs/run');
    if (res && res.ok) {
        toast('Check FAQs scan iniciado (Playwright)...', 'info');
        const s = $('#cfScanStatus'); if (s) s.textContent = 'scanning…';
        setTimeout(refreshCheckfaqs, 8000);
        setTimeout(refreshCheckfaqs, 30000);
    } else if (res && res.status === 'running') {
        toast('Scan já está em execução', 'warning');
    } else {
        toast('Falha ao iniciar scan', 'error');
    }
}

async function openCheckfaqsDiff(firm, key) {
    const data = await api('/checkfaqs/firm?name=' + encodeURIComponent(firm));
    if (!data) return;
    const p = (data.pages || []).find(x => x.key === key);
    if (!p) return;
    const modal = $('#dnaViewerModal');
    if (!modal) return;
    const esc = (s) => (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    $('#dnaViewerTitle').textContent = firm + ' — ' + p.type + ' (ANTES / DEPOIS)';

    const before = (p.previous_text || '').trim();
    const after = (p.text || '').trim();
    const textChanged = before !== after;

    const prevPrices = p.previous_prices || [];
    const curPrices = p.prices || [];
    const prevDisc = p.previous_discounts || [];
    const curDisc = p.discounts || [];
    const priceAdded = curPrices.filter(x => !prevPrices.includes(x));
    const priceRemoved = prevPrices.filter(x => !curPrices.includes(x));
    const discAdded = curDisc.filter(x => !prevDisc.includes(x));
    const discRemoved = prevDisc.filter(x => !curDisc.includes(x));
    const pricesChanged = priceAdded.length || priceRemoved.length || discAdded.length || discRemoved.length;

    let html = '';

    if (textChanged) {
        html += '<div class="cf-diff">' +
            '<div><div class="cf-diff-h">ANTES</div><pre class="cf-pre">' + esc(before || '(sem texto)') + '</pre></div>' +
            '<div><div class="cf-diff-h">DEPOIS</div><pre class="cf-pre">' + esc(after || '(sem texto)') + '</pre></div>' +
            '</div>';
    }

    if (pricesChanged) {
        if (textChanged) html += '<div style="border-top:1px solid #333;margin:10px 0"></div>';
        html += '<div style="padding:10px 15px">';
        if (priceAdded.length || priceRemoved.length) {
            html += '<div style="margin-bottom:15px"><div class="cf-diff-h">PREÇOS</div>';
            html += '<table class="watchlist-table" style="font-size:12px"><thead><tr><th>STATUS</th><th>PREÇO</th></tr></thead><tbody>';
            priceRemoved.forEach(x => { html += '<tr style="color:#ff6b6b"><td>REMOVIDO</td><td>' + esc(x) + '</td></tr>'; });
            priceAdded.forEach(x => { html += '<tr style="color:#5fbf6f"><td>ADICIONADO</td><td>' + esc(x) + '</td></tr>'; });
            html += '</tbody></table></div>';
        }
        if (discAdded.length || discRemoved.length) {
            html += '<div><div class="cf-diff-h">DESCONTOS</div>';
            html += '<table class="watchlist-table" style="font-size:12px"><thead><tr><th>STATUS</th><th>DESCONTO</th></tr></thead><tbody>';
            discRemoved.forEach(x => { html += '<tr style="color:#ff6b6b"><td>REMOVIDO</td><td>' + esc(x) + '</td></tr>'; });
            discAdded.forEach(x => { html += '<tr style="color:#5fbf6f"><td>ADICIONADO</td><td>' + esc(x) + '</td></tr>'; });
            html += '</tbody></table></div>';
        }
        html += '</div>';
    }

    if (!html) {
        html = '<div style="padding:20px;color:#888;text-align:center">Mudança detectada (hash alterado), mas sem diff de texto ou preços disponível.</div>';
    }

    $('#dnaViewerContent').innerHTML = html;
    modal.classList.add('open');
}

/* ── AI Agents Dashboard ── */
async function loadAgentsTab() {
    const c = $('#tabAgents');
    if (!c) return;

    const agentsDef = [
        { name: 'ATLAS',  role: 'Supervisor Geral',    group: 'command',   row: 0 },
        { name: 'HELENA', role: 'Chief Risk Officer',   group: 'supervisors', row: 1 },
        { name: 'DANTE',  role: 'Code Auditor',         group: 'supervisors', row: 1 },
        { name: 'SOPHIA', role: 'Data Auditor',         group: 'supervisors', row: 1 },
        { name: 'ARTHUR', role: 'Process Auditor',      group: 'supervisors', row: 1 },
        { name: 'MARCUS', role: 'Desk Forex',           group: 'operators',  row: 2 },
        { name: 'VICTOR', role: 'Desk Indices',         group: 'operators',  row: 2 },
        { name: 'HELIOS', role: 'Desk Commodities',     group: 'operators',  row: 2 },
        { name: 'ATHENA', role: 'Desk Stocks',          group: 'operators',  row: 2 },
        { name: 'NEXUS',  role: 'Red Team / QA',        group: 'operators',  row: 2 },
        { name: 'CLARA',  role: 'Reporting / CFO',      group: 'output',   row: 3 },
    ];

    let statusData = {};
    let taskData = [];
    let danteStats = {};
    try {
        const [statusResp, tasksResp, statsResp] = await Promise.all([
            api('/agents/status'),
            api('/agent-tasks'),
            api('/dante/stats')
        ]);
        if (statusResp && statusResp.agents) statusData = statusResp.agents;
        if (tasksResp && tasksResp.tasks) taskData = tasksResp.tasks;
        if (statsResp && statsResp.ok) danteStats = statsResp;
    } catch(e) {}

    const enabledAgents = new Set();
    for (const t of taskData) {
        if (t.enabled) enabledAgents.add(t.agent);
    }

    function makeCard(a) {
        const s = statusData[a.name] || {};
        let st = s.status || 'STANDBY';
        if (a.name === 'ATLAS') st = 'ONLINE';
        if (enabledAgents.has(a.name) && st === 'STANDBY') st = 'ONLINE';
        if (a.name === 'DANTE') {
            const crit = (danteStats.by_severity || {}).critical || 0;
            const high = (danteStats.by_severity || {}).high || 0;
            if (crit > 0 || high > 0) st = 'ERROR';
        }
        const hb = s.heartbeat ? timeAgo(s.heartbeat) : '—';
        const errs = s.errors_today || 0;
        const click = a.name === 'DANTE' ? 'onclick="openDanteModal()"' : `onclick="openAgentModal('${a.name}')"`;
        const warnBadge = (a.name === 'DANTE' && st === 'ERROR')
            ? '<span style="color:#ff5252;font-size:7px;margin-left:4px">⚠ ALERT</span>' : '';
        return `
        <div class="agent-card" ${click}>
            <div class="agent-card-row1">
                <span class="agent-card-name">${a.name}${warnBadge}</span>
                <span><span class="agent-status-dot ${st}"></span><span style="color:#777;font-size:8px">${st}</span></span>
            </div>
            <div class="agent-card-role">${a.role}</div>
            <div class="agent-card-metrics">
                <span><span class="metric-icon">&#9829;</span>${hb}</span>
                <span><span class="metric-icon">&#10007;</span>${errs} erros</span>
            </div>
        </div>`;
    }

    const commandRow  = agentsDef.filter(a => a.group === 'command');
    const superRow    = agentsDef.filter(a => a.group === 'supervisors');
    const operatorsRow = agentsDef.filter(a => a.group === 'operators');
    const outputRow   = agentsDef.filter(a => a.group === 'output');

    c.innerHTML = `
    <div class="macro-state-section">
        <div class="macro-state-header">AI AGENTS — FLOW</div>
    </div>
    <div class="flowchart">
        <div class="flow-row">${commandRow.map(makeCard).join('')}</div>
        <div class="flow-line-v"></div>
        <div class="flow-connector"></div>
        <div class="agent-group-label">Supervisores</div>
        <div class="flow-row">${superRow.map(makeCard).join('')}</div>
        <div class="flow-line-v"></div>
        <div class="flow-connector"></div>
        <div class="agent-group-label">Operadores</div>
        <div class="flow-row">${operatorsRow.map(makeCard).join('')}</div>
        <div class="flow-line-v"></div>
        <div class="flow-connector"></div>
        <div class="agent-group-label">Output</div>
        <div class="flow-row">${outputRow.map(makeCard).join('')}</div>
    </div>
    <div id="agentTasksPanel"></div>`;

    await loadAgentTasks();
}

function timeAgo(isoStr) {
    if (!isoStr) return '—';
    try {
        const diff = (Date.now() - new Date(isoStr).getTime()) / 1000;
        if (diff < 60) return `${Math.floor(diff)}s`;
        if (diff < 3600) return `${Math.floor(diff / 60)}min`;
        if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
        return `${Math.floor(diff / 86400)}d`;
    } catch { return '—'; }
}

let _agentModalInterval = null;

function openAgentModal(name) {
    if (_agentModalInterval) { clearInterval(_agentModalInterval); _agentModalInterval = null; }
    const overlay = document.createElement('div');
    overlay.id = 'agentModalOverlay';
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.7);z-index:9998;display:flex;align-items:center;justify-content:center';
    overlay.onclick = (e) => { if (e.target === overlay) closeAgentModal(); };

    const modal = document.createElement('div');
    modal.id = 'agentModal';
    modal.style.cssText = 'background:#111;border:1px solid #333;border-radius:6px;padding:20px;width:420px;max-height:80vh;overflow-y:auto;color:#e0e0e0';

    modal.innerHTML = `
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;border-bottom:1px solid #222;padding-bottom:10px">
            <div>
                <div style="color:#ff9800;font-size:16px;font-weight:bold">${name}</div>
                <div id="agentModalRole" style="color:#888;font-size:11px"></div>
            </div>
            <div onclick="closeAgentModal()" style="cursor:pointer;color:#666;font-size:18px">&times;</div>
        </div>
        <div id="agentModalBody" style="font-size:12px;color:#aaa">Carregando...</div>`;

    overlay.appendChild(modal);
    document.body.appendChild(overlay);

    async function refresh() {
        try {
            const resp = await api('/agents/status');
            const a = (resp.agents || {})[name] || {};
            const hb = a.heartbeat ? timeAgo(a.heartbeat) : '—';
            const st = a.status || 'STANDBY';
            const errs = a.errors_today || 0;
            const role = a.role || '—';
            $('#agentModalRole').textContent = role;
            $('#agentModalBody').innerHTML = `
                <div style="display:flex;gap:16px;margin-bottom:14px">
                    <div style="flex:1;background:#1a1a1a;border:1px solid #222;border-radius:4px;padding:10px;text-align:center">
                        <div style="color:#555;font-size:9px;margin-bottom:4px">STATUS</div>
                        <div><span class="agent-status-dot ${st}"></span><span style="color:#ccc;font-size:12px">${st}</span></div>
                    </div>
                    <div style="flex:1;background:#1a1a1a;border:1px solid #222;border-radius:4px;padding:10px;text-align:center">
                        <div style="color:#555;font-size:9px;margin-bottom:4px">HEARTBEAT</div>
                        <div style="color:#ccc;font-size:12px">${hb}</div>
                    </div>
                    <div style="flex:1;background:#1a1a1a;border:1px solid #222;border-radius:4px;padding:10px;text-align:center">
                        <div style="color:#555;font-size:9px;margin-bottom:4px">ERROS HOJE</div>
                        <div style="color:${errs > 0 ? '#ff5252' : '#ccc'};font-size:12px">${errs}</div>
                    </div>
                </div>
                <div style="background:#1a1a1a;border:1px solid #222;border-radius:4px;padding:10px">
                    <div style="color:#555;font-size:9px;margin-bottom:6px">ULTIMO LOG</div>
                    <div style="color:#666;font-size:10px;font-family:monospace">Nenhum log disponivel</div>
                </div>`;
        } catch(e) {
            $('#agentModalBody').innerHTML = '<div style="color:#ff5252">Erro ao carregar</div>';
        }
    }
    refresh();
    _agentModalInterval = setInterval(refresh, 10000);
}

function closeAgentModal() {
    if (_agentModalInterval) { clearInterval(_agentModalInterval); _agentModalInterval = null; }
    const o = $('#agentModalOverlay');
    if (o) o.remove();
}

async function loadAgentTasks() {
    const panel = $('#agentTasksPanel');
    if (!panel) return;
    const resp = await api('/agent-tasks');
    const tasks = (resp && resp.tasks) ? resp.tasks : [];
    if (tasks.length === 0) {
        panel.innerHTML = '';
        return;
    }
    const fmtInterval = (min) => {
        if (min === 0) return 'Manual';
        if (min < 60) return `${min}min`;
        if (min === 60) return '1h';
        if (min < 1440) return `${(min/60).toFixed(0)}h`;
        return `${(min/1440).toFixed(0)}d`;
    };
    const fmtTime = (iso) => {
        if (!iso) return '—';
        const d = new Date(iso);
        return d.toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit' });
    };
    let rows = '';
    for (const t of tasks) {
        const sevColor = t.enabled ? '#00ff88' : '#666';
        rows += `
        <tr>
            <td style="font-size:10px;font-weight:bold;color:${sevColor}">${t.agent}</td>
            <td style="font-size:10px">${t.name}</td>
            <td style="font-size:9px;color:#888;max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${t.description}</td>
            <td style="font-size:10px">
                <select onchange="updateTaskInterval('${t.id}', this.value)" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:2px 4px;font-size:9px">
                    <option value="0" ${t.interval_minutes===0?'selected':''}>Manual</option>
                    <option value="15" ${t.interval_minutes===15?'selected':''}>15min</option>
                    <option value="30" ${t.interval_minutes===30?'selected':''}>30min</option>
                    <option value="60" ${t.interval_minutes===60?'selected':''}>1h</option>
                    <option value="240" ${t.interval_minutes===240?'selected':''}>4h</option>
                    <option value="480" ${t.interval_minutes===480?'selected':''}>8h</option>
                    <option value="1440" ${t.interval_minutes===1440?'selected':''}>24h</option>
                </select>
            </td>
            <td style="font-size:10px">
                <select onchange="updateTaskWindow('${t.id}', this.value)" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:2px 4px;font-size:9px">
                    <option value="" ${!t.run_window?'selected':''}>Sempre</option>
                    <option value="22:00-00:00" ${t.run_window==='22:00-00:00'?'selected':''}>22h-00h</option>
                    <option value="06:00-08:00" ${t.run_window==='06:00-08:00'?'selected':''}>06h-08h</option>
                    <option value="18:00-20:00" ${t.run_window==='18:00-20:00'?'selected':''}>18h-20h</option>
                </select>
            </td>
            <td style="font-size:9px;color:#888">${fmtTime(t.last_run)}</td>
            <td style="font-size:10px">
                <label style="cursor:pointer;display:flex;align-items:center;gap:4px">
                    <input type="checkbox" ${t.enabled ? 'checked' : ''} onchange="toggleTask('${t.id}', this.checked)">
                    <span style="color:${sevColor}">${t.enabled ? 'ON' : 'OFF'}</span>
                </label>
            </td>
            <td style="font-size:10px">
                <button class="tf-btn" onclick="runTaskNow('${t.id}')" ${t.endpoint ? '' : 'disabled title="Sem endpoint"'} style="font-size:9px;padding:1px 6px">RUN</button>
            </td>
        </tr>`;
    }
    panel.innerHTML = `
    <div style="margin-top:16px">
        <div class="macro-state-section">
            <div class="macro-state-header" style="font-size:9px">
                <span>AGENT TASKS — Agendamento</span>
                <button class="tf-btn" onclick="loadAgentTasks()" style="font-size:9px;padding:1px 6px">REFRESH</button>
            </div>
        </div>
        <div style="overflow:auto">
            <table class="watchlist-table">
                <thead><tr>
                    <th style="font-size:10px">AGENTE</th>
                    <th style="font-size:10px">TAREFA</th>
                    <th style="font-size:10px">DESCRICAO</th>
                    <th style="font-size:10px">INTERVALO</th>
                    <th style="font-size:10px">JANELA</th>
                    <th style="font-size:10px">ULT. EXECUCAO</th>
                    <th style="font-size:10px">STATUS</th>
                    <th style="font-size:10px"></th>
                </tr></thead>
                <tbody>${rows}</tbody>
            </table>
        </div>
    </div>`;
}

async function toggleTask(taskId, enabled) {
    await api('/agent-tasks/toggle', 10000, 'POST', { task_id: taskId, enabled });
    await loadAgentTasks();
}

async function updateTaskInterval(taskId, interval) {
    await api('/agent-tasks/update', 10000, 'POST', { task_id: taskId, interval_minutes: parseInt(interval) });
    await loadAgentTasks();
}

async function updateTaskWindow(taskId, window) {
    await api('/agent-tasks/update', 10000, 'POST', { task_id: taskId, run_window: window });
    await loadAgentTasks();
}

async function runTaskNow(taskId) {
    const res = await api('/agent-tasks/run-now', 300000, 'POST', { task_id: taskId });
    if (res && res.ok && res.executed) {
        toast(`Tarefa executada: ${res.task.name}`, 'info');
    } else if (res && res.ok) {
        toast(`Tarefa registrada: ${res.task.name} (sem endpoint automatico)`, 'info');
    } else {
        toast('Erro: ' + (res ? res.error : 'falha'), 'error');
    }
    await loadAgentTasks();
}

/* ── DANTE Code Auditor Modal ── */
let _danteFindings = [];
let _danteFilterSev = '';
let _danteFilterFile = '';

function openDanteModal() {
    let overlay = $('#danteModal');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'danteModal';
        overlay.className = 'modal-overlay';
        overlay.onclick = (e) => { if (e.target === overlay) closeModal('danteModal'); };
        overlay.innerHTML = `
        <div class="modal" onclick="event.stopPropagation()" style="max-width:95vw;width:95vw;height:85vh;display:flex;flex-direction:column">
            <div class="panel-header" style="border:none;background:transparent;justify-content:space-between">
                <span>DANTE — AI Code Auditor</span>
                <span style="display:flex;align-items:center;gap:8px">
                    <button class="tf-btn" onclick="danteRunScan()" id="danteScanBtn">RUN SCAN</button>
                    <button class="tf-btn" onclick="danteClear()" style="margin-left:4px">CLEAR</button>
                    <span id="danteScanStatus" style="color:#888;font-size:11px;margin-left:8px"></span>
                </span>
            </div>
            <div id="danteContent" style="flex:1;overflow:auto;padding:0 12px 12px;color:#888;font-size:13px">Carregando...</div>
        </div>`;
        document.body.appendChild(overlay);
    }
    overlay.classList.add('open');
    danteRefresh();
}

function danteRenderTable() {
    const tableEl = $('#danteTableBody');
    const countEl = $('#danteCount');
    if (!tableEl) return;
    const sevColor = { critical: '#ff1744', high: '#ff9100', medium: '#ffab00', low: '#66bb6a', info: '#42a5f5' };
    let filtered = _danteFindings;
    if (_danteFilterSev) filtered = filtered.filter(f => f.severity === _danteFilterSev);
    if (_danteFilterFile) filtered = filtered.filter(f => (f.file_path || '').includes(_danteFilterFile));
    const rows = filtered.slice(0, 200).map(f =>
        `<tr>
            <td style="color:${sevColor[f.severity] || '#888'};font-size:13px">${(f.severity || '').toUpperCase()}</td>
            <td style="color:#00bcd4;font-size:13px">${f.rule_id || ''}</td>
            <td style="max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px" title="${f.file_path || ''}">${(f.file_path || '').split(/[/\\\\]/).pop()}</td>
            <td style="font-size:13px">${f.line || ''}</td>
            <td style="max-width:500px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px">${f.message || ''}</td>
            <td style="font-size:13px">${f.source || 'tool'}</td>
        </tr>`
    ).join('');
    tableEl.innerHTML = rows;
    if (countEl) countEl.textContent = `Mostrando ${Math.min(filtered.length, 200)} de ${filtered.length} findings${(_danteFilterSev || _danteFilterFile) ? ' (filtrado)' : ''}`;
}

async function danteRefresh() {
    const [stats, findingsResp] = await Promise.all([
        api('/dante/stats'),
        api('/dante/findings')
    ]);

    const el = $('#danteContent');
    if (!el) return;

    if (!stats || !stats.ok) {
        el.innerHTML = `<div style="color:#ff5252;padding:12px;font-size:14px">Erro ao carregar DANTE: ${stats ? stats.error : 'API indisponivel'}</div>`;
        return;
    }

    _danteFindings = (findingsResp && findingsResp.ok) ? findingsResp.findings : [];
    const bySev = stats.by_severity || {};
    const crit = bySev.critical || 0;
    const high = bySev.high || 0;
    const med = bySev.medium || 0;
    const low = bySev.low || 0;
    const info = bySev.info || 0;

    const uniqueFiles = [...new Set(_danteFindings.map(f => (f.file_path || '').split(/[/\\\\]/).pop()))].sort();
    const fileOptions = uniqueFiles.map(fn => `<option value="${fn}">${fn}</option>`).join('');

    let summaryHtml = `
    <div style="display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-bottom:12px">
        <div class="risk-card" style="border-left:3px solid #ff1744">
            <div class="risk-card-header"><span class="risk-card-title" style="color:#ff1744;font-size:22px">${crit}</span></div>
            <div style="color:#888;font-size:13px">CRITICO</div>
        </div>
        <div class="risk-card" style="border-left:3px solid #ff9100">
            <div class="risk-card-header"><span class="risk-card-title" style="color:#ff9100;font-size:22px">${high}</span></div>
            <div style="color:#888;font-size:13px">ALTO</div>
        </div>
        <div class="risk-card" style="border-left:3px solid #ffab00">
            <div class="risk-card-header"><span class="risk-card-title" style="color:#ffab00;font-size:22px">${med}</span></div>
            <div style="color:#888;font-size:13px">MEDIO</div>
        </div>
        <div class="risk-card" style="border-left:3px solid #66bb6a">
            <div class="risk-card-header"><span class="risk-card-title" style="color:#66bb6a;font-size:22px">${low}</span></div>
            <div style="color:#888;font-size:13px">BAIXO</div>
        </div>
        <div class="risk-card" style="border-left:3px solid #42a5f5">
            <div class="risk-card-header"><span class="risk-card-title" style="color:#42a5f5;font-size:22px">${info}</span></div>
            <div style="color:#888;font-size:13px">INFO</div>
        </div>
    </div>`;

    let excludeHtml = '';
    try {
        const exclResp = await api('/dante/exclude-folders');
        const exclFolders = (exclResp && exclResp.exclude_folders) ? exclResp.exclude_folders : [];
        const exclRows = exclFolders.map(f =>
            `<tr>
                <td style="font-size:11px;color:#ccc;font-family:monospace">${f}</td>
                <td style="font-size:11px;text-align:center"><button class="tf-btn" onclick="danteRemoveExclude('${f.replace(/'/g, "\\'")}')" style="font-size:9px;padding:1px 6px;color:#ff5252">DEL</button></td>
            </tr>`
        ).join('');
        excludeHtml = `
        <div style="margin-bottom:12px;border:1px solid #222;border-radius:4px;padding:10px;background:#111">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                <span style="color:#ff9800;font-size:11px;font-weight:bold">PASTAS EXCLUIDAS DO SCAN</span>
            </div>
            <div style="display:flex;gap:6px;margin-bottom:8px;align-items:center">
                <label class="tf-btn" style="font-size:9px;padding:4px 10px;cursor:pointer;display:inline-flex;align-items:center;gap:4px">
                    &#128193; Selecionar Pasta
                    <input type="file" webkitdirectory id="danteExclPicker" style="display:none" onchange="danteOnFolderPicked(this)">
                </label>
                <span id="danteExclPicked" style="color:#666;font-size:9px;font-family:monospace"></span>
                <button class="tf-btn" onclick="danteAddExcludePicked()" id="danteExclAddBtn" style="font-size:9px;padding:4px 10px;display:none">+ ADD</button>
                <span style="color:#555;font-size:9px;margin:0 4px">ou</span>
                <input id="danteExclInput" type="text" placeholder="caminho\pasta" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:3px;padding:3px 6px;font-size:10px;width:220px">
                <button class="tf-btn" onclick="danteAddExclude()" style="font-size:9px;padding:4px 10px">+ ADD</button>
            </div>
            ${exclFolders.length > 0 ? `
            <table class="watchlist-table">
                <thead><tr><th style="font-size:10px;text-align:left">PASTA</th><th style="font-size:10px;width:40px"></th></tr></thead>
                <tbody>${exclRows}</tbody>
            </table>` : '<div style="color:#555;font-size:10px;text-align:center;padding:6px">Nenhuma pasta excluida</div>'}
        </div>`;
    } catch(e) {}

    let filterHtml = '';
    if (_danteFindings.length > 0) {
        filterHtml = `
        <div style="display:flex;gap:12px;margin-bottom:8px;align-items:center">
            <label style="color:#888;font-size:12px">Severity:</label>
            <select id="danteFilterSev" onchange="_danteFilterSev=this.value;danteRenderTable()" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:4px 8px;font-size:13px">
                <option value="">TODOS</option>
                <option value="critical" ${_danteFilterSev==='critical'?'selected':''}>CRITICO</option>
                <option value="high" ${_danteFilterSev==='high'?'selected':''}>ALTO</option>
                <option value="medium" ${_danteFilterSev==='medium'?'selected':''}>MEDIO</option>
                <option value="low" ${_danteFilterSev==='low'?'selected':''}>BAIXO</option>
                <option value="info" ${_danteFilterSev==='info'?'selected':''}>INFO</option>
            </select>
            <label style="color:#888;font-size:12px">Arquivo:</label>
            <select id="danteFilterFile" onchange="_danteFilterFile=this.value;danteRenderTable()" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:4px 8px;font-size:13px;min-width:180px">
                <option value="">TODOS</option>
                ${fileOptions}
            </select>
        </div>`;
    }

    let tableHtml = '';
    if (_danteFindings.length > 0) {
        tableHtml = `
        <div style="overflow:auto;max-height:calc(85vh - 260px)">
            <table class="watchlist-table">
                <thead><tr><th style="font-size:13px">SEVERITY</th><th style="font-size:13px">RULE</th><th style="font-size:13px">FILE</th><th style="font-size:13px">LINE</th><th style="font-size:13px">MESSAGE</th><th style="font-size:13px">SOURCE</th></tr></thead>
                <tbody id="danteTableBody"></tbody>
            </table>
        </div>
        <div id="danteCount" style="color:#666;font-size:12px;margin-top:4px"></div>`;
    } else {
        tableHtml = '<div style="text-align:center;padding:20px;color:#666;font-size:14px">Nenhum finding. Execute um scan primeiro.</div>';
    }

    el.innerHTML = summaryHtml + excludeHtml + filterHtml + tableHtml;
    danteRenderTable();
}

let _dantePickedFolder = '';

function danteOnFolderPicked(input) {
    const file = input.files[0];
    if (!file) return;
    const path = file.webkitRelativePath || '';
    const folderName = path.split('/')[0] || '';
    _dantePickedFolder = folderName;
    const label = $('#danteExclPicked');
    const btn = $('#danteExclAddBtn');
    if (label) label.textContent = folderName;
    if (btn) btn.style.display = 'inline-flex';
}

async function danteAddExcludePicked() {
    if (!_dantePickedFolder) return;
    await api('/dante/exclude-folders', 10000, 'POST', { folder: _dantePickedFolder });
    _dantePickedFolder = '';
    const picker = $('#danteExclPicker');
    const label = $('#danteExclPicked');
    const btn = $('#danteExclAddBtn');
    if (picker) picker.value = '';
    if (label) label.textContent = '';
    if (btn) btn.style.display = 'none';
    await danteRefresh();
}

async function danteAddExclude() {
    const input = $('#danteExclInput');
    if (!input || !input.value.trim()) return;
    await api('/dante/exclude-folders', 10000, 'POST', { folder: input.value.trim() });
    input.value = '';
    await danteRefresh();
}

async function danteRemoveExclude(folder) {
    await api('/dante/exclude-folders', 10000, 'DELETE', { folder });
    await danteRefresh();
}

async function danteRunScan() {
    const btn = $('#danteScanBtn');
    const status = $('#danteScanStatus');
    if (btn) btn.disabled = true;
    if (status) status.textContent = 'Escaneando com LLM...';
    _danteFilterSev = '';
    _danteFilterFile = '';
    const res = await api('/dante/scan', 600000, 'POST', { use_llm: true });
    if (btn) btn.disabled = false;
    if (status) status.textContent = '';
    if (res && res.ok) {
        toast(`DANTE scan concluido: ${res.stats?.findings || 0} findings em ${res.elapsed?.toFixed(1) || '?'}s`, 'info');
    } else {
        toast('Erro no scan: ' + (res ? res.error : 'API indisponivel'), 'error');
    }
    if ($('#danteContent')) {
        await danteRefresh();
    }
}

async function danteClear() {
    _danteFilterSev = '';
    _danteFilterFile = '';
    await api('/dante/clear', 10000, 'POST');
    toast('Sessao DANTE limpa', 'info');
    await danteRefresh();
}

/* ── Load Everything ── */
let _loadAllBusy = false;
async function loadAll() {
    if (_loadAllBusy) return;
    _loadAllBusy = true;
    try {
        loadStatus();
        loadSymbols();
        loadRisk();
        loadMacro();
        if (currentTab !== 'checkfaqs') loadTabData(currentTab);
        renderActiveTabLog();
    } finally {
        _loadAllBusy = false;
    }
}

/* ══════════════════════════════════════════════════
   DATAHOUSE TAB
   ══════════════════════════════════════════════════ */
async function loadDatahouse() {
    const c = $('#tabDatahouse');
    if (!c) return;
    const first = c.dataset.loaded !== '1';
    if (first) {
        c.innerHTML = '<div style="text-align:center;padding:20px;color:#666">Loading Datahouse...</div>';
    }

    /* Load all data in parallel */
    const [health, pending, schedules, status] = await Promise.all([
        api('/health'),
        api('/health/pending'),
        api('/schedules'),
        api('/status')
    ]);

    if (first) {
        c.innerHTML = `
        <div class="datahouse-grid">
            <!-- Watchlist / Symbols -->
            <div class="tab-panel datahouse-watchlist">
                <div class="tab-panel-header">
                    <span>WATCHLIST • SYMBOLS</span>
                    <span style="color:#666;font-size:10px" id="dhSymbolCount">0 symbols</span>
                </div>
                <div class="tab-panel-content" style="padding:0;max-height:300px;overflow-y:auto">
                    <table class="watchlist-table">
                        <thead>
                            <tr><th>SYM</th><th>TF</th><th>LAST</th><th>AGE</th><th>STATUS</th></tr>
                        </thead>
                        <tbody id="dhWatchlistBody"></tbody>
                    </table>
                </div>
            </div>

            <!-- Macro Economic -->
            <div class="tab-panel datahouse-macro">
                <div class="tab-panel-header">
                    <span>MACRO ECONOMIC</span>
                    <span style="color:#666;font-size:10px" id="dhMacroDate">—</span>
                </div>
                <div class="tab-panel-content" style="padding:0;max-height:300px;overflow-y:auto">
                    <table class="watchlist-table">
                        <thead>
                            <tr><th></th><th>INDICATOR</th><th>VALUE</th><th>UNIT</th></tr>
                        </thead>
                        <tbody id="dhMacroBody"></tbody>
                    </table>
                </div>
            </div>

            <!-- Data Health -->
            <div class="tab-panel">
                <div class="tab-panel-header">
                    <span>DATA HEALTH</span>
                    <span id="dhOverall"></span>
                </div>
                <div class="tab-panel-content">
                    <div id="datahouseHealth"></div>
                </div>
            </div>

            <!-- System Metrics -->
            <div class="tab-panel">
                <div class="tab-panel-header">
                    <span>SYSTEM METRICS</span>
                    <span style="color:#666;font-size:10px">DB Overview</span>
                </div>
                <div class="tab-panel-content">
                    <div class="portfolio-summary">
                        <div class="portfolio-item"><span class="portfolio-label">TOTAL ROWS</span><span class="portfolio-value" id="dhTotalRows"></span></div>
                        <div class="portfolio-item"><span class="portfolio-label">DOMAINS OK</span><span class="portfolio-value positive" id="dhOk"></span></div>
                        <div class="portfolio-item"><span class="portfolio-label">OUTDATED</span><span class="portfolio-value" style="color:#ff9800" id="dhStale"></span></div>
                        <div class="portfolio-item"><span class="portfolio-label">CRITICAL</span><span class="portfolio-value" style="color:#ff5252" id="dhCritical"></span></div>
                    </div>
                    <hr style="border-color:#222;margin:8px 0">
                    <div style="font-size:10px;color:#666" id="dhSummary"></div>
                    <div class="domain-heatmap" id="datahouseHeatmap"></div>
                </div>
            </div>

            <!-- Windows Tasks Scheduler -->
            <div class="tab-panel" style="grid-column: span 2">
                <div class="tab-panel-header">
                    <span>WINDOWS TASKS • SCHEDULER</span>
                    <span id="dhTaskCount" style="color:#666;font-size:10px"></span>
                </div>
                <div class="tab-panel-content">
                    <table class="level2-table" id="taskTable">
                        <thead>
                            <tr><th>TASK</th><th>FREQ</th><th>LAST RUN</th><th>STATUS</th></tr>
                        </thead>
                        <tbody id="taskBody"></tbody>
                    </table>
                    <div style="margin-top:10px;display:flex;gap:6px">
                        <button class="tf-btn" onclick="actionRegister()">REGISTER</button>
                        <button class="tf-btn" onclick="actionRemove()">REMOVE</button>
                        <button class="tf-btn active" onclick="loadDatahouse()">REFRESH</button>
                    </div>
                </div>
            </div>
        </div>`;
        c.dataset.loaded = '1';
    }

    _refreshDatahouse(health, pending, schedules, status);
}

function _refreshDatahouse(health, pending, schedules, status) {
    const overall = health?.overall || 'unknown';
    const overallCls = overall === 'ok' ? 'positive' : (overall === 'warning' ? 'neutral' : 'negative');
    const summary = status?.summary || {};
    const totalRows = summary.total_rows || 0;
    const okCount = summary.ok || 0;
    const staleCount = summary.stale || 0;
    const criticalCount = summary.critical || 0;
    const pendingTotal = pending?.total || 0;

    const overallEl = $('#dhOverall');
    if (overallEl) {
        overallEl.textContent = overall;
        overallEl.className = overallCls;
        overallEl.style.fontWeight = 'bold';
        overallEl.style.textTransform = 'uppercase';
        overallEl.style.fontSize = '10px';
    }

    const healthEl = $('#datahouseHealth');
    if (healthEl) {
        let html = '';
        if (pendingTotal > 0 && overall !== 'ok') {
            html += `
            <div style="background:#2a2000;border:1px solid #ff9800;border-radius:4px;padding:8px 10px;margin-bottom:10px;font-size:10px;display:flex;justify-content:space-between;align-items:center">
                <div><span style="color:#ff9800;font-weight:bold">⚠ ${pendingTotal} item(s)</span> need repair</div>
                <button class="tf-btn" style="padding:3px 10px;font-size:9px" onclick="actionRepair('all')">REPAIR ALL</button>
            </div>`;
        }
        html += `<div id="datahouseHealthList">${_renderHealthDomains(health?.domains || [])}</div>`;
        healthEl.innerHTML = html;
    }

    const setText = (id, val) => { const e = $('#' + id); if (e) e.textContent = val; };
    setText('dhTotalRows', fmtNum(totalRows));
    setText('dhOk', okCount);
    setText('dhStale', staleCount);
    setText('dhCritical', criticalCount);
    setText('dhSummary', `${okCount} OK / ${staleCount} stale / ${criticalCount} critical`);
    setText('dhTaskCount', `${schedules?.length || 0} tasks`);

    const heatEl = $('#datahouseHeatmap');
    if (heatEl && status?.domains) {
        heatEl.innerHTML = '';
        status.domains.forEach(d => {
            const b = document.createElement('div');
            b.className = 'sector-box ' + (d.status || 'ok');
            b.innerHTML = `<div>${d.domain}</div><div style="font-size:14px">${d.status.toUpperCase()}</div><div class="small">${fmtNum(d.rows || 0)} rows</div>`;
            heatEl.appendChild(b);
        });
    }

    const taskBody = $('#taskBody');
    if (taskBody && schedules) {
        taskBody.innerHTML = '';
        schedules.forEach(t => {
            const tr = document.createElement('tr');
            const statusCls = t.exists ? 'positive' : 'negative';
            const statusText = t.exists ? (t.windows_status === 'Ready' ? 'READY' : t.windows_status) : 'NOT FOUND';
            tr.innerHTML = `
                <td style="color:#ff9800;font-weight:bold;text-align:left">${t.task.replace('ALXQuant-','')}</td>
                <td>${t.domain}<br><span style="color:#666">${t.label}</span></td>
                <td style="font-size:10px">${t.last_run || '—'}</td>
                <td class="${statusCls}">${statusText}</td>`;
            taskBody.appendChild(tr);
        });
    }
}

function _renderHealthDomains(domains) {
    if (!domains || domains.length === 0) return '<div style="color:#666;padding:10px;text-align:center">No domain data available</div>';
    let html = '<div style="display:flex;flex-direction:column;gap:6px">';
    domains.forEach(d => {
        const s = d.status || 'critical';
        const sCls = s === 'ok' ? 'positive' : (s === 'stale' ? 'neutral' : 'negative');
        const age = d.age_hours !== null && d.age_hours !== undefined && d.age_hours < 999999
            ? (d.age_hours < 1 ? (d.age_hours * 60).toFixed(0) + 'm' : d.age_hours.toFixed(1) + 'h')
            : '—';
        const last = d.last_update ? d.last_update.slice(0, 10) : '—';
        const rows = d.rows || 0;
        html += `
            <div style="display:flex;justify-content:space-between;align-items:center;padding:6px 8px;background-color:#1a1a1a;border-radius:4px;border-left:3px solid ${s === 'ok' ? '#00ff88' : (s === 'stale' ? '#ff9800' : '#ff5252')}">
                <div>
                    <div style="font-weight:bold;font-size:11px">${d.domain}</div>
                    <div style="color:#666;font-size:10px">${d.table || '—'} · ${rows.toLocaleString()} rows</div>
                </div>
                <div style="text-align:right">
                    <div class="${sCls}" style="font-weight:bold;font-size:10px;text-transform:uppercase">${s}</div>
                    <div style="color:#666;font-size:10px">${age} · last ${last}</div>
                </div>
            </div>`;
    });
    html += '</div>';
    return html;
}

/* ══════════════════════════════════════════════════
   NEWS TAB (ForexFactory Calendar)
   ══════════════════════════════════════════════════ */
let _newsLoading = false;

async function loadNewsTab() {
    const c = $('#tabNews');
    if (!c) return;
    const first = c.dataset.loaded !== '1';
    if (first) {
        c.innerHTML = `
        <div class="panel-header" style="justify-content:space-between">
            <span>NEWS — ForexFactory Calendar</span>
            <span>
                <button class="tf-btn active" onclick="runNewsFetch()">REFRESH</button>
                <span id="newsFetchStatus" style="color:#888;font-size:11px;margin-left:8px"></span>
            </span>
        </div>
        <div style="display:flex;gap:8px;align-items:center;padding:8px 10px;border-bottom:1px solid #333;flex-wrap:wrap">
            <div style="display:flex;flex-direction:column;gap:2px">
                <label style="color:#666;font-size:9px;text-transform:uppercase">Currency</label>
                <select id="newsCurrency" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:4px 6px;font-size:11px">
                    <option value="">All</option>
                    <option value="USD">USD</option>
                    <option value="EUR">EUR</option>
                    <option value="GBP">GBP</option>
                    <option value="JPY">JPY</option>
                    <option value="CAD">CAD</option>
                    <option value="AUD">AUD</option>
                    <option value="NZD">NZD</option>
                    <option value="CNY">CNY</option>
                    <option value="CHF">CHF</option>
                </select>
            </div>
            <div style="display:flex;flex-direction:column;gap:2px">
                <label style="color:#666;font-size:9px;text-transform:uppercase">Impact</label>
                <select id="newsImpact" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:4px 6px;font-size:11px">
                    <option value="">All</option>
                    <option value="HIGH">High</option>
                    <option value="MEDIUM">Medium</option>
                    <option value="LOW">Low</option>
                </select>
            </div>
            <div style="display:flex;flex-direction:column;gap:2px">
                <label style="color:#666;font-size:9px;text-transform:uppercase">Days</label>
                <select id="newsDays" style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:4px 6px;font-size:11px">
                    <option value="1">Today</option>
                    <option value="3">3 days</option>
                    <option value="7" selected>7 days</option>
                    <option value="14">14 days</option>
                    <option value="30">30 days</option>
                </select>
            </div>
            <div style="display:flex;flex-direction:column;gap:2px;flex:1;min-width:150px">
                <label style="color:#666;font-size:9px;text-transform:uppercase">Search</label>
                <input id="newsSearch" placeholder="Filter events..." style="background:#1a1a1a;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:4px 6px;font-size:11px">
            </div>
            <div style="display:flex;flex-direction:column;gap:2px">
                <label style="color:#666;font-size:9px;text-transform:uppercase">&nbsp;</label>
                <button class="tf-btn" onclick="refreshNews()">FILTER</button>
            </div>
        </div>
        <div class="panel-content" style="overflow:auto">
            <table class="watchlist-table" id="newsTable">
                <thead><tr>
                    <th>DATE/TIME</th><th>CURRENCY</th><th>IMPACT</th><th>EVENT</th>
                    <th>FORECAST</th><th>PREVIOUS</th><th>ACTUAL</th>
                </tr></thead>
                <tbody></tbody>
            </table>
            <div id="newsCount" style="color:#666;font-size:11px;padding:6px 10px;text-align:right"></div>
        </div>`;
        c.dataset.loaded = '1';
        const searchEl = $('#newsSearch');
        if (searchEl) searchEl.addEventListener('keydown', e => { if (e.key === 'Enter') refreshNews(); });
    }

    await refreshNews();
}

async function refreshNews() {
    if (_newsLoading) return;
    _newsLoading = true;
    const statusEl = $('#newsFetchStatus');
    if (statusEl) statusEl.textContent = 'loading…';

    try {
        const currency = ($('#newsCurrency') || {}).value || '';
        const impact = ($('#newsImpact') || {}).value || '';
        const days = parseInt(($('#newsDays') || {}).value || '7');
        const search = ($('#newsSearch') || {}).value || '';

        const params = new URLSearchParams();
        if (currency) params.set('currency', currency);
        if (impact) params.set('impact', impact);
        if (days) params.set('days', days);
        if (search) params.set('search', search);

        const data = await api('/news?' + params.toString());

        const tbody = $('#newsTable tbody');
        if (!tbody) return;
        tbody.innerHTML = '';

        if (!data || !data.ok || !data.events) {
            tbody.innerHTML = '<tr><td colspan="7" style="color:#666;text-align:center;padding:20px">No events found. Click REFRESH to fetch.</td></tr>';
            return;
        }

        const now = Date.now() / 1000;
        data.events.forEach(ev => {
            const tr = document.createElement('tr');
            const impactColor = { HIGH: '#ff4444', MEDIUM: '#ffaa00', LOW: '#666', HOLIDAY: '#8844aa', SPEAKER: '#4488aa',
                High: '#ff4444', Medium: '#ffaa00', Low: '#666', 'Holiday/Speaker': '#8844aa' }[ev.impact] || '#666';
            const isPast = ev.event_time < now;
            tr.style.opacity = isPast ? '0.5' : '1';
            tr.innerHTML = `
                <td style="white-space:nowrap">${ev.date_str || ''}</td>
                <td style="font-weight:bold;color:#00bcd4">${ev.currency || ''}</td>
                <td><span style="color:${impactColor};font-weight:bold">${ev.impact || ''}</span></td>
                <td>${ev.event_name || ''}</td>
                <td style="text-align:right">${ev.forecast != null ? ev.forecast : ''}</td>
                <td style="text-align:right">${ev.previous != null ? ev.previous : ''}</td>
                <td style="text-align:right;font-weight:bold">${ev.actual != null ? ev.actual : ''}</td>`;
            tbody.appendChild(tr);
        });

        const countEl = $('#newsCount');
        if (countEl) countEl.textContent = `${data.count} events`;
    } finally {
        _newsLoading = false;
        if (statusEl) statusEl.textContent = '';
    }
}

async function runNewsFetch() {
    const statusEl = $('#newsFetchStatus');
    if (statusEl) statusEl.textContent = 'fetching…';
    const res = await api('/news/run');
    if (res && res.ok) {
        // Poll for completion
        let tries = 0;
        const poll = setInterval(async () => {
            tries++;
            const stats = await api('/news/stats');
            if (stats && stats.ok) {
                clearInterval(poll);
                if (statusEl) statusEl.textContent = '';
                await refreshNews();
            }
            if (tries > 30) { clearInterval(poll); if (statusEl) statusEl.textContent = 'timeout'; }
        }, 2000);
    } else {
        if (statusEl) statusEl.textContent = res && res.status === 'running' ? 'already running…' : 'error';
    }
}

/* ══════════════════════════════════════════════════
   ASSET DNA TAB
   ══════════════════════════════════════════════════ */
let _assetDnaRunning = false;
let _lastDnaSymbol = null;
let _lastDnaTf = null;

function loadAssetDnaTab() {
    if ($('#dnaReportsPanel')) return;
    const c = $('#tabAssetDna');
    c.innerHTML = `
    <div class="asset-dna-controls">
        <div style="display:flex;flex-direction:column;gap:4px">
            <label style="color:#666;font-size:9px;text-transform:uppercase">Symbol</label>
            <select class="asset-dna-select" id="dnaSymbol"></select>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px">
            <label style="color:#666;font-size:9px;text-transform:uppercase">Timeframe</label>
            <select class="asset-dna-select" id="dnaTf">
                <option value="M5">M5</option>
                <option value="M1">M1</option>
            </select>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px">
            <label style="color:#666;font-size:9px;text-transform:uppercase">Period</label>
            <select class="asset-dna-select" id="dnaYears">
                <option value="1">1 Year</option>
                <option value="2">2 Years</option>
                <option value="3">3 Years</option>
                <option value="5" selected>5 Years</option>
                <option value="7">7 Years</option>
                <option value="10">10 Years</option>
            </select>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <button class="tf-btn active" onclick="runAssetDnaFromTab()" id="dnaRunBtn">RUN PROFILER</button>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <button class="tf-btn" onclick="runMacroOverlayFromTab()" id="dnaOverlayBtn" disabled title="Requires profile JSON first">RUN OVERLAY</button>
        </div>
        <div style="flex:1;display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <div style="color:#666;font-size:10px" id="dnaStatus">Select symbol, period and run Asset DNA profiler</div>
        </div>
    </div>

    <div class="asset-dna-advanced" id="dnaAdvanced">
        <div class="asset-dna-advanced-toggle" onclick="toggleDnaAdvanced()">
            <span>&#9654; Advanced Options</span>
            <span id="dnaAdvArrow">&#9660;</span>
        </div>
        <div class="asset-dna-advanced-content" id="dnaAdvContent" style="display:none">
            <label class="dna-toggle"><input type="checkbox" id="dnaSkipPdf"> Skip PDF (JSON only, faster)</label>
            <label class="dna-toggle"><input type="checkbox" id="dnaSkipInst"> Skip Institutional (no PBO / Optimal Stopping)</label>
        </div>
    </div>

    <div class="asset-dna-reports" id="dnaReportsPanel">
        <div class="asset-dna-reports-header">
            <span>ASSET DNA REPORTS</span>
            <span style="color:#666" id="dnaReportsCount"></span>
        </div>
        <div class="asset-dna-reports-body" id="dnaReportsList">
            <div style="color:#666;padding:10px;text-align:center;font-size:10px">Loading reports...</div>
        </div>
    </div>

    <div class="dna-overlay-status" id="dnaOverlayStatus" style="display:none">
        <div class="dna-overlay-header">
            <span>MACRO OVERLAY STATUS</span>
            <span style="color:#666;font-size:10px" id="dnaOverlayInfo"></span>
        </div>
        <div class="dna-overlay-body" id="dnaOverlayBody"></div>
    </div>

    <div class="dna-progress-bar" id="dnaProgressBar" style="display:none">
        <div class="dna-progress-bar-fill" id="dnaProgressFill" style="width:0%"></div>
    </div>

    <div class="dna-inline-log" id="dnaInlineLog">
        <div class="dna-inline-log-header">
            <span>EXECUTION LOG</span>
            <span style="color:#ff9800;font-weight:bold" id="dnaLogPhase"></span>
        </div>
        <div class="dna-inline-log-body" id="dnaLogBody"></div>
    </div>`;

    _populateSymbolSelect('#dnaSymbol');
    loadDnaReports();
}

function toggleDnaAdvanced() {
    const content = $('#dnaAdvContent');
    const arrow = $('#dnaAdvArrow');
    if (content.style.display === 'none') {
        content.style.display = 'flex';
        arrow.innerHTML = '&#9660;';
    } else {
        content.style.display = 'none';
        arrow.innerHTML = '&#9654;';
    }
}

function _getDnaParams() {
    const sym = $('#dnaSymbol')?.value || 'XAUUSD';
    const tf = $('#dnaTf')?.value || 'M5';
    const years = $('#dnaYears')?.value || '5';
    const skipPdf = $('#dnaSkipPdf')?.checked || false;
    const skipInst = $('#dnaSkipInst')?.checked || false;
    return { sym, tf, years, skipPdf, skipInst };
}

/* ── Reports List ── */
async function loadDnaReports() {
    const list = $('#dnaReportsList');
    const count = $('#dnaReportsCount');
    if (!list) return;
    const data = await api('/asset-dna/list');
    if (!data) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:10px">No reports found</div>';
        if (count) count.textContent = '';
        return;
    }
    const rows = [];
    const symbols = new Set();
    for (const j of (data.json || [])) {
        symbols.add(j.symbol);
        const d = new Date(j.modified);
        const dateStr = d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', {hour:'2-digit',minute:'2-digit'});
        rows.push({ sym: j.symbol, name: j.name, type: 'JSON', size: j.size_kb > 1024 ? (j.size_kb/1024).toFixed(1)+' MB' : j.size_kb+' KB', date: dateStr, modified: d.getTime() });
    }
    for (const p of (data.pdf || [])) {
        symbols.add(p.symbol);
        const d = new Date(p.modified);
        const dateStr = d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', {hour:'2-digit',minute:'2-digit'});
        rows.push({ sym: p.symbol, name: p.name, type: 'PDF', size: p.size_kb > 1024 ? (p.size_kb/1024).toFixed(1)+' MB' : p.size_kb+' KB', date: dateStr, modified: d.getTime() });
    }
    for (const t of (data.txt || [])) {
        symbols.add(t.symbol);
        const d = new Date(t.modified);
        const dateStr = d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', {hour:'2-digit',minute:'2-digit'});
        rows.push({ sym: t.symbol, name: t.name, type: 'TXT', size: t.size_kb > 1024 ? (t.size_kb/1024).toFixed(1)+' MB' : t.size_kb+' KB', date: dateStr, modified: d.getTime() });
    }
    rows.sort((a, b) => b.modified - a.modified);
    if (count) count.textContent = `${symbols.size} assets, ${rows.length} files`;
    if (rows.length === 0) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:10px">No reports yet — run the profiler to generate one</div>';
        return;
    }
    let html = '<table class="asset-dna-reports-table"><thead><tr><th>SYM</th><th>TYPE</th><th>SIZE</th><th>LAST RUN</th><th></th></tr></thead><tbody>';
    for (const r of rows) {
        const typeClass = r.type === 'PDF' ? 'dna-type-pdf' : r.type === 'TXT' ? 'dna-type-txt' : 'dna-type-json';
        html += `<tr><td style="cursor:pointer" onclick="openDnaReport('${r.sym}','${r.type}','${r.name}')">${r.sym}</td><td><span class="${typeClass}" style="cursor:pointer" onclick="openDnaReport('${r.sym}','${r.type}','${r.name}')">${r.type}</span></td><td>${r.size}</td><td>${r.date}</td><td><span class="dna-delete-btn" onclick="event.stopPropagation();deleteDnaReport('${r.sym}','${r.type}','${r.name}')" title="Delete">&#128465;</span></td></tr>`;
    }
    html += '</tbody></table>';
    list.innerHTML = html;

    // Enable/disable overlay button based on whether profile JSON exists for selected symbol
    const selSym = $('#dnaSymbol')?.value;
    const hasJson = (data.json || []).some(j => j.symbol === selSym);
    const overlayBtn = $('#dnaOverlayBtn');
    if (overlayBtn) {
        overlayBtn.disabled = !hasJson;
        overlayBtn.title = hasJson ? 'Run Macro Overlay' : 'Requires profile JSON first';
    }

    // Load overlay status for selected symbol
    if (selSym) loadOverlayStatus(selSym);
}

/* ── Run Profiler ── */
async function runAssetDnaFromTab() {
    if (_assetDnaRunning) return;
    _assetDnaRunning = true;
    const p = _getDnaParams();
    const btn = $('#dnaRunBtn');
    const status = $('#dnaStatus');
    const logBody = $('#dnaLogBody');
    const progressBar = $('#dnaProgressBar');

    btn.disabled = true;
    btn.textContent = 'RUNNING...';
    btn.style.opacity = '0.5';
    btn.classList.add('dna-running');
    status.textContent = `Starting Asset DNA profiler for ${p.sym} ${p.tf} (${p.years}Y)...`;
    status.style.color = '#ff9800';

    if (logBody) { logBody.innerHTML = ''; _dnaLogReady = true; }
    if (progressBar) { progressBar.style.display = 'block'; }
    const fill = $('#dnaProgressFill');
    if (fill) fill.style.width = '0%';
    const phase = $('#dnaLogPhase');
    if (phase) phase.textContent = '';

    _dnaLogReady = false;
    _dnaLogLastId = 0;

    const startTime = Date.now();
    const elapsedTimer = setInterval(() => {
        if (!_assetDnaRunning) return;
        const secs = Math.floor((Date.now() - startTime) / 1000);
        const mins = Math.floor(secs / 60);
        const rem = secs % 60;
        const timeStr = mins > 0 ? `${mins}m ${rem}s` : `${secs}s`;
        const phaseText = phase ? phase.textContent : '';
        status.textContent = phaseText ? `${phaseText} — ${timeStr}` : `Running... ${timeStr}`;
    }, 1000);

    let url = `/asset-dna/run?symbol=${p.sym}&tf=${p.tf}&years=${p.years}`;
    if (p.skipPdf) url += '&skip_pdf=true';
    if (p.skipInst) url += '&skip_institutional=true';

    const res = await api(url, 900000);
    clearInterval(elapsedTimer);

    btn.disabled = false;
    btn.textContent = 'RUN PROFILER';
    btn.style.opacity = '1';
    btn.classList.remove('dna-running');
    _assetDnaRunning = false;

    if (res && res.ok) {
        _lastDnaSymbol = p.sym;
        _lastDnaTf = p.tf;
        status.textContent = `✓ Asset DNA profile ready for ${p.sym}`;
        status.style.color = '#00ff88';
        if (fill) fill.style.width = '100%';
        if (phase) phase.textContent = 'DONE 100%';
        toast(`Asset DNA profile ready for ${p.sym}`, 'info');
        loadDnaReports();
        // Auto-run overlay if enabled
        const overlaySettings = await api('/settings/overlay');
        if (overlaySettings?.auto_run !== false) {
            setTimeout(() => runMacroOverlay(p.sym, p.tf), 500);
        }
    } else {
        const err = res?.error || res?.stderr || 'unknown error';
        status.textContent = `✗ Asset DNA failed: ${err.slice(0, 120)}`;
        status.style.color = '#ff5252';
        toast(`Asset DNA FAIL: ${err.slice(0, 100)}`, 'error');
        if (fill) fill.style.width = '0%';
        if (phase) phase.textContent = 'FAILED';
    }
}

async function _populateSymbolSelect(selector) {
    const symbols = await api('/symbols');
    if (!symbols) return;
    const sel = $(selector);
    const seen = new Set();
    symbols.forEach(s => {
        if (!seen.has(s.symbol)) {
            seen.add(s.symbol);
            const opt = document.createElement('option');
            opt.value = s.symbol;
            opt.textContent = s.symbol;
            sel.appendChild(opt);
        }
    });
}

/* ── Delete Report ── */
async function deleteDnaReport(sym, type, name) {
    const typeLabel = type === 'PDF' ? 'PDF' : 'JSON';
    if (!confirm(`Deletar ${typeLabel} de ${sym}?`)) return;
    const tf = 'M5';
    const endpoint = type === 'TXT' ? `/macro-overlay/delete/${sym}` : `/asset-dna/delete/${sym}?tf=${tf}&type=${type.toLowerCase()}`;
    const res = await api(endpoint);
    if (res && res.ok) {
        toast(`${typeLabel} de ${sym} deletado`, 'info');
        loadDnaReports();
    } else {
        toast(`Falha ao deletar ${typeLabel} de ${sym}`, 'error');
    }
}

/* ── Run Macro Overlay ── */
let _macroOverlayRunning = false;

function runMacroOverlayFromTab() {
    const p = _getDnaParams();
    runMacroOverlay(p.sym, p.tf);
}

async function runMacroOverlay(symbol, tf) {
    if (_macroOverlayRunning) return;
    _macroOverlayRunning = true;
    const btn = $('#dnaOverlayBtn');
    const status = $('#dnaStatus');

    if (btn) {
        btn.disabled = true;
        btn.textContent = 'RUNNING...';
        btn.style.opacity = '0.5';
    }
    if (status) {
        status.textContent = `Running Macro Overlay for ${symbol}...`;
        status.style.color = '#ff9800';
    }

    const res = await api(`/macro-overlay/run?symbol=${symbol}&tf=${tf}`, 120000);
    _macroOverlayRunning = false;

    if (btn) {
        btn.disabled = false;
        btn.textContent = 'RUN OVERLAY';
        btn.style.opacity = '1';
    }

    if (res && res.ok) {
        if (status) {
            status.textContent = `✓ Macro Overlay ready for ${symbol}`;
            status.style.color = '#00ff88';
        }
        toast(`Macro Overlay ready for ${symbol}`, 'info');
        loadDnaReports();
        loadOverlayStatus(symbol);
    } else {
        const err = res?.error || res?.stderr || 'unknown error';
        if (status) {
            status.textContent = `✗ Macro Overlay failed: ${err.slice(0, 120)}`;
            status.style.color = '#ff5252';
        }
        toast(`Macro Overlay FAIL: ${err.slice(0, 100)}`, 'error');
    }
}

/* ── Overlay Status Card ── */
async function loadOverlayStatus(symbol) {
    const container = $('#dnaOverlayStatus');
    const body = $('#dnaOverlayBody');
    const info = $('#dnaOverlayInfo');
    if (!container || !body) return;

    const res = await api(`/macro-overlay/status/${symbol}`);
    if (!res || !res.ok) {
        container.style.display = 'none';
        return;
    }

    const data = res.data;
    container.style.display = 'block';

    const regime = data.regime_score || 'UNKNOWN';
    const allowMr = data.allow_mean_reversion;
    const overlay = data.overlay || {};

    if (info) {
        info.textContent = `${data.symbol} | ${data.timeframe}`;
    }

    let html = `<div class="dna-overlay-summary">
        <span class="dna-overlay-regime">${regime}</span>
        <span class="dna-overlay-mr ${allowMr ? 'mr-on' : 'mr-off'}">MR: ${allowMr ? 'ON' : 'OFF'}</span>
    </div>`;

    if (Object.keys(overlay).length > 0) {
        html += '<table class="dna-overlay-table"><thead><tr><th>INDICATOR</th><th>Z-SCORE</th><th>CORR</th><th>LAG</th><th>STATUS</th></tr></thead><tbody>';
        for (const [sym, d] of Object.entries(overlay)) {
            const z = d.z_score;
            const zAbs = Math.abs(z);
            const statusClass = zAbs > 2 ? 'z-extreme' : zAbs > 1.5 ? 'z-high' : zAbs > 1 ? 'z-elevated' : 'z-normal';
            const statusText = zAbs > 2 ? 'EXTREME' : zAbs > 1.5 ? 'HIGH' : zAbs > 1 ? 'ELEVATED' : 'NORMAL';
            const corr = d.hist_corr_close_ret;
            const lag = d.best_lag_days;
            html += `<tr>
                <td>${sym}</td>
                <td>${z >= 0 ? '+' : ''}${z.toFixed(3)}</td>
                <td>${corr != null ? corr.toFixed(3) : '—'}</td>
                <td>${lag || '—'}</td>
                <td><span class="dna-z-badge ${statusClass}">${statusText}</span></td>
            </tr>`;
        }
        html += '</tbody></table>';
    } else {
        html += '<div style="color:#666;padding:8px;text-align:center;font-size:10px">No overlay data available</div>';
    }

    body.innerHTML = html;
}

/* ── PDF/JSON/TXT Viewer ── */
function openDnaReport(sym, type, name) {
    const modal = $('#dnaViewerModal');
    const title = $('#dnaViewerTitle');
    const content = $('#dnaViewerContent');
    if (!modal || !content) return;

    title.textContent = `${sym} — ${type} Report`;
    content.innerHTML = '<div class="dna-viewer-loading">Loading...</div>';
    modal.classList.add('open');

    if (type === 'JSON') {
        _loadJsonReport(sym, content);
    } else if (type === 'TXT') {
        _loadTxtReport(sym, content);
    } else {
        _loadPdfReport(sym, content);
    }
}

async function _loadJsonReport(sym, container) {
    const data = await api(`/asset-dna/json/${sym}`, 30000);
    if (!data) {
        container.innerHTML = '<div class="dna-viewer-loading">Failed to load JSON</div>';
        return;
    }
    const formatted = JSON.stringify(data, null, 2);
    const escaped = formatted
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
    const highlighted = escaped
        .replace(/"([^"]+)":/g, '<span class="json-key">"$1"</span>:')
        .replace(/: "([^"]*)"/g, ': <span class="json-str">"$1"</span>')
        .replace(/: (-?\d+\.?\d*)/g, ': <span class="json-num">$1</span>')
        .replace(/: (true|false)/g, ': <span class="json-bool">$1</span>')
        .replace(/: (null)/g, ': <span class="json-null">$1</span>');
    container.innerHTML = `<div class="dna-viewer-json">${highlighted}</div>`;
}

function _loadTxtReport(sym, container) {
    const res = api(`/macro-overlay/json/${sym}`, 10000);
    res.then(data => {
        if (!data) {
            container.innerHTML = '<div class="dna-viewer-loading">Failed to load overlay data</div>';
            return;
        }
        let html = '<div class="dna-json-viewer">';
        html += `<div class="dna-json-section">`;
        html += `<div class="dna-json-key">symbol</div><div class="dna-json-val">${data.symbol || '—'}</div>`;
        html += `<div class="dna-json-key">timeframe</div><div class="dna-json-val">${data.timeframe || '—'}</div>`;
        html += `<div class="dna-json-key">regime</div><div class="dna-json-val">${data.regime_score || '—'}</div>`;
        html += `<div class="dna-json-key">allow_mean_reversion</div><div class="dna-json-val">${data.allow_mean_reversion ? 'YES' : 'NO'}</div>`;
        html += `</div>`;
        if (data.overlay && Object.keys(data.overlay).length > 0) {
            html += '<div class="dna-json-section"><div class="dna-json-section-title">Overlay Indicators</div>';
            for (const [sym, d] of Object.entries(data.overlay)) {
                html += `<div class="dna-json-key">${sym}</div><div class="dna-json-val">z=${d.z_score} corr=${d.hist_corr_close_ret} lag=${d.best_lag_days}</div>`;
            }
            html += '</div>';
        }
        html += '</div>';
        container.innerHTML = html;
    });
}

function _loadPdfReport(sym, container) {
    container.innerHTML = `<iframe src="/api/asset-dna/pdf/${encodeURIComponent(sym)}" style="width:100%;height:100%;border:none"></iframe>`;
}

/* ══════════════════════════════════════════════════
   REGIME TAB
   ══════════════════════════════════════════════════ */
async function loadRegimeTab() {
    const c = $('#tabRegime');
    if (!c) return;
    const first = c.dataset.loaded !== '1';
    if (first) c.innerHTML = '<div style="text-align:center;padding:20px;color:#666">Loading Regime data...</div>';

    const symbols = await api('/symbols');
    const seen = new Set();
    const uniqueSymbols = [];
    if (symbols) {
        symbols.forEach(s => {
            if (!seen.has(s.symbol)) {
                seen.add(s.symbol);
                uniqueSymbols.push(s);
            }
        });
    }

    if (uniqueSymbols.length === 0) {
        if (first) c.innerHTML = '<div style="color:#666;padding:20px;text-align:center">No symbols available. Check data pipeline.</div>';
        return;
    }

    const sig = _sigOf(uniqueSymbols.map(s => s.symbol));
    const cur = ($('#regimeSymbol') && $('#regimeSymbol').value) ? $('#regimeSymbol').value : 'XAUUSD';
    const selected = uniqueSymbols.some(s => s.symbol === cur) ? cur : (uniqueSymbols[0].symbol || 'XAUUSD');

    if (!first && !_changed(c, sig)) {
        loadRegimeForSymbol(selected);
        return;
    }
    c.dataset.loaded = '1';
    if (!_changed(c, sig)) return;

    /* Build regime grid for each symbol */
    let html = '<div style="display:flex;gap:10px;margin-bottom:12px;flex-wrap:wrap">';
    html += '<div style="display:flex;flex-direction:column;gap:4px">';
    html += '<label style="color:#666;font-size:9px;text-transform:uppercase">Select Symbol</label>';
    html += '<select class="asset-dna-select" id="regimeSymbol" onchange="loadRegimeForSymbol(this.value)">';
    uniqueSymbols.forEach(s => {
        const sel = s.symbol === selected ? 'selected' : '';
        html += `<option value="${s.symbol}" ${sel}>${s.symbol}</option>`;
    });
    html += '</select></div>';
    html += '<div style="flex:1;color:#666;font-size:10px;padding-top:16px" id="regimeInfo">Select a symbol to view regime analysis</div>';
    html += '</div>';
    html += '<div class="regime-grid" id="regimeGrid"></div>';
    c.innerHTML = html;

    /* Load regime for selected symbol */
    loadRegimeForSymbol(selected);
}

async function loadRegimeForSymbol(sym) {
    const grid = $('#regimeGrid');
    if (!grid) return;

    /* Try to get regime data from Asset DNA profile */
    const profile = await api(`/asset-dna/profile/${sym}`);
    const sig = _sigOf(profile);
    if (!_changed(grid, sig)) return;
    grid.innerHTML = '<div style="color:#666;padding:20px;text-align:center">Loading regime analysis...</div>';

    const info = $('#regimeInfo');
    if (info) info.textContent = `Regime analysis for ${sym} (from Asset DNA profile)`;

    if (!profile) {
        grid.innerHTML = `
        <div style="text-align:center;padding:30px;color:#666">
            <div style="font-size:24px;margin-bottom:8px">⚠</div>
            <div>No Asset DNA profile found for ${sym}</div>
            <div style="font-size:10px;margin-top:8px;color:#888">Run Asset DNA profiler first (click ASSET DNA tab → RUN PROFILER)</div>
        </div>`;
        return;
    }

    const regime = profile.regime_analysis || {};
    const features = profile.feature_importance || {};
    const meta = profile.metadata || {};
    const hurst = profile.hurst_analysis || {};
    const entropy = profile.entropy_analysis || {};

    /* Create regime cards */
    let html = '';

    /* Current Regime Card */
    const currentRegime = regime.dominant_regime || 'UNKNOWN';
    const regimeLabel = currentRegime.replace(/_/g, ' ');
    const regimeBadgeCls = `regime-badge-${currentRegime.toLowerCase()}`;

    html += `
    <div class="regime-card">
        <div class="regime-card-header">
            <span class="regime-card-title">Current Regime</span>
            <span class="regime-card-badge ${regimeBadgeCls}">${regimeLabel}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Dominant</span>
            <span class="regime-metric-value" style="color:#ff9800;font-weight:bold">${regimeLabel}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Timeframe</span>
            <span class="regime-metric-value">${meta.timeframe || 'M5'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Last Update</span>
            <span class="regime-metric-value" style="font-size:9px">${meta.last_update?.slice(0, 16) || '—'}</span>
        </div>
    </div>`;

    /* Hurst Card */
    const hurstVal = hurst.hurst_exponent !== undefined ? hurst.hurst_exponent : null;
    const hurstCls = hurstVal !== null ? (hurstVal > 0.55 ? 'positive' : hurstVal < 0.45 ? 'negative' : 'warning') : '';
    html += `
    <div class="regime-card">
        <div class="regime-card-header">
            <span class="regime-card-title">Hurst Analysis</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Hurst Exponent (DFA)</span>
            <span class="regime-metric-value ${hurstCls}">${hurstVal !== null ? hurstVal.toFixed(3) : '—'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Interpretation</span>
            <span class="regime-metric-value" style="font-size:10px">${hurstVal !== null ? (hurstVal > 0.55 ? 'Trending' : hurstVal < 0.45 ? 'Mean-Reverting' : 'Random Walk') : '—'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Sample Entropy</span>
            <span class="regime-metric-value">${entropy.sample_entropy !== undefined ? entropy.sample_entropy.toFixed(3) : '—'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Permutation Entropy</span>
            <span class="regime-metric-value">${entropy.permutation_entropy !== undefined ? entropy.permutation_entropy.toFixed(3) : '—'}</span>
        </div>
    </div>`;

    /* ADX / Trend Card */
    const adxVal = regime.adx_value !== undefined ? regime.adx_value : null;
    const r2Val = regime.confidence_r2 !== undefined ? regime.confidence_r2 : null;
    html += `
    <div class="regime-card">
        <div class="regime-card-header">
            <span class="regime-card-title">Trend Strength</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">ADX</span>
            <span class="regime-metric-value">${adxVal !== null ? adxVal.toFixed(1) : '—'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">ADX Interpretation</span>
            <span class="regime-metric-value" style="font-size:10px">${adxVal !== null ? (adxVal > 25 ? 'Trending' : 'Range-Bound') : '—'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">R² (Confidence)</span>
            <span class="regime-metric-value">${r2Val !== null ? r2Val.toFixed(3) : '—'}</span>
        </div>
        <div class="regime-metric">
            <span class="regime-metric-label">Volatility Regime</span>
            <span class="regime-metric-value" style="font-size:10px">${regime.volatility_regime || '—'}</span>
        </div>
    </div>`;

    grid.innerHTML = html;
}

/* ══════════════════════════════════════════════════
   RISK SENTIMENT TAB
   ══════════════════════════════════════════════════ */
function setMacroRefreshIndicator(container, active) {
    if (!container) return;
    const existing = container.querySelector('.macro-refresh-status');
    if (active) {
        if (existing) return;
        const section = container.querySelector('.macro-state-section');
        if (!section) return;
        const el = document.createElement('div');
        el.className = 'macro-refresh-status';
        el.innerHTML = '<span class="macro-refresh-dot"></span><span>Atualizando macroeconomia…</span>';
        section.appendChild(el);
        return;
    }
    if (existing) existing.remove();
}

async function loadRiskSentimentTab() {
    const c = $('#tabRiskSentiment');
    if (!c) return;

    const alreadyLoaded = c.dataset.loaded === '1' && c.innerHTML.trim().length > 0;
    if (alreadyLoaded) {
        setMacroRefreshIndicator(c, true);
    } else {
        c.innerHTML = `
        <div class="risk-grid">
            <div class="risk-card" style="grid-row: span 2">
                <div class="risk-card-header"><span class="risk-card-title">Risk Score</span></div>
                <div style="color:#666;font-size:11px;padding:30px;text-align:center">Carregando dados de risco...</div>
            </div>
            <div class="risk-card">
                <div class="risk-card-header"><span class="risk-card-title">Market Indicators</span></div>
                <div style="color:#666;font-size:11px;padding:30px;text-align:center">Loading...</div>
            </div>
            <div class="risk-card">
                <div class="risk-card-header"><span class="risk-card-title">Yield Curve</span></div>
                <div style="color:#666;font-size:11px;padding:30px;text-align:center">Loading...</div>
            </div>
        </div>
        <div class="macro-state-section">
            <div class="macro-state-header">GLOBAL MACRO ECONOMIC STATE</div>
            <div style="color:#888;font-size:11px;padding:10px">Carregando macroeconomia...</div>
        </div>`;
    }

    const [risk, macro] = await Promise.all([api('/risk'), api('/macro-state')]);
    const riskEmpty = !risk || Object.keys(risk).length === 0;
    const macroEmpty = !macro || !macro.economies || Object.keys(macro.economies).length === 0;

    if (alreadyLoaded && !risk && !macro) {
        setMacroRefreshIndicator(c, true);
        return;
    }

    if (!risk && !macro) {
        if (!alreadyLoaded) {
            c.dataset.loaded = '1';
        }
        setMacroRefreshIndicator(c, false);
        return;
    }

    const riskNote = riskEmpty ? '<div style="color:#888;font-size:11px;padding:0 2px 10px">Risk sentiment indisponível no momento.</div>' : '';
    const riskHtml = riskNote + riskSentimentHtml(riskEmpty ? {} : risk);
    const html = riskHtml + macroStateHtml(macroEmpty ? null : macro);
    const sig = (riskEmpty ? 'risk-empty' : '') + '|' + riskSentimentSig(riskEmpty ? {} : risk) + '|' + macroStateSig(macroEmpty ? null : macro);

    if (c.dataset.loaded === '1' && c.dataset.sig === sig) {
        setMacroRefreshIndicator(c, false);
        return;
    }
    c.dataset.loaded = '1';
    c.dataset.sig = sig;
    if (alreadyLoaded && !riskEmpty && !macroEmpty) {
        c.innerHTML = html;
        setMacroRefreshIndicator(c, false);
        return;
    }
    c.innerHTML = html;
    setMacroRefreshIndicator(c, false);
}

function riskSentimentSig(risk) {
    const g = (x) => (x === undefined || x === null) ? '' : x;
    return [g(risk.date), g(risk.risk_label), g(risk.roro_score), g(risk.signal_strength),
            g(risk.roro_kcroro_z), g(risk.roro_pca), g(risk.global_risk_score),
            g(risk.vix), g(risk.dxy), g(risk.equity_sp), g(risk.gold), g(risk.credit_hy),
            g(risk.equity_intl), g(risk.roro_v4), g(risk.roro_credit), g(risk.roro_equity_vol),
            g(risk.roro_funding), g(risk.roro_fx_gold), g(risk.yield_2y), g(risk.yield_10y),
            g(risk.yield_2y_prev), g(risk.vix_chg), g(risk.dxy_chg)].join('|');
}

function riskSentimentHtml(risk) {
    const riskLabel = risk.risk_label || 'NEUTRAL';
    const roroScore = risk.roro_score || 0;
    const signalStrength = risk.signal_strength || 'low';
    const riskCls = riskLabel === 'RISK_ON' ? 'risk-on' : riskLabel === 'RISK_OFF' ? 'risk-off' : 'neutral';
    const date = risk.date || '—';
    const num = (x, d, pct) => (x !== undefined && x !== null) ? (Number(x).toFixed(d === undefined ? 2 : d) + (pct ? '%' : '')) : '—';
    const chgSpan = (chg) => (chg !== undefined && chg !== null)
        ? `<span style="font-size:9px;color:${chg > 0 ? '#ff5252' : '#00ff88'}">${chg >= 0 ? '+' : ''}${Number(chg).toFixed(2)}</span>` : '';
    const curveCls = (risk.yield_10y !== undefined && risk.yield_2y !== undefined && (risk.yield_10y - risk.yield_2y) < 0) ? 'negative' : 'positive';
    const curve = (risk.yield_10y !== undefined && risk.yield_2y !== undefined) ? ((risk.yield_10y - risk.yield_2y) * 100).toFixed(1) + 'bp' : '—';
    let html = `
    <div class="risk-grid">
        <div class="risk-card" style="grid-row: span 2">
            <div class="risk-card-header"><span class="risk-card-title">Risk Score</span><span style="color:#666;font-size:9px">${date}</span></div>
            <div style="text-align:center;padding:20px 0">
                <div class="risk-score-large ${riskCls}">${num(roroScore)}</div>
                <div style="margin-top:8px"><span style="padding:4px 12px;border-radius:4px;font-size:11px;font-weight:bold;background:${riskLabel === 'RISK_ON' ? '#27AE60' : riskLabel === 'RISK_OFF' ? '#E74C3C' : '#F39C12'};color:${riskLabel === 'NEUTRAL' ? '#000' : '#fff'}">${riskLabel}</span></div>
                <div style="margin-top:6px;color:#888;font-size:10px">Signal Strength: ${signalStrength}</div>
            </div>
            <div style="margin-top:15px">
                <div class="risk-factor-row"><span class="risk-factor-label">KCRORO</span><span class="risk-factor-value">${num(risk.roro_kcroro_z, 3)}</span></div>
                <div class="risk-factor-row"><span class="risk-factor-label">PCA RORO</span><span class="risk-factor-value">${num(risk.roro_pca, 3)}</span></div>
                <div class="risk-factor-row"><span class="risk-factor-label">Global Risk Score</span><span class="risk-factor-value">${num(risk.global_risk_score, 3)}</span></div>
            </div>
        </div>
        <div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">Market Indicators</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">VIX</span><span class="risk-factor-value ${risk.vix_chg > 0 ? 'negative' : risk.vix_chg < 0 ? 'positive' : ''}">${num(risk.vix)} ${chgSpan(risk.vix_chg)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">DXY</span><span class="risk-factor-value">${num(risk.dxy)} ${chgSpan(risk.dxy_chg)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">S&P 500</span><span class="risk-factor-value">${num(risk.equity_sp)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">GOLD</span><span class="risk-factor-value">${num(risk.gold)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">US 10Y Yield</span><span class="risk-factor-value">${num(risk.yield_10y, 2, true)}</span></div>
        </div>
        <div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">Risk Factors</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">Credit (HY)</span><span class="risk-factor-value">${num(risk.credit_hy, 3)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">Equity SP</span><span class="risk-factor-value">${num(risk.equity_sp)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">Equity Intl</span><span class="risk-factor-value">${num(risk.equity_intl)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">GOLD</span><span class="risk-factor-value">${num(risk.gold)}</span></div>
        </div>
        <div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">V4 Sub-Indices</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">RORO V4</span><span class="risk-factor-value">${num(risk.roro_v4, 3)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">RORO Credit</span><span class="risk-factor-value">${num(risk.roro_credit, 3)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">RORO Equity Vol</span><span class="risk-factor-value">${num(risk.roro_equity_vol, 3)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">RORO Funding</span><span class="risk-factor-value">${num(risk.roro_funding, 3)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">RORO FX/Gold</span><span class="risk-factor-value">${num(risk.roro_fx_gold, 3)}</span></div>
        </div>
        <div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">Yield Curve</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">US 2Y</span><span class="risk-factor-value">${num(risk.yield_2y, 2, true)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">US 10Y</span><span class="risk-factor-value">${num(risk.yield_10y, 2, true)}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">Curve (2Y-10Y)</span><span class="risk-factor-value ${curveCls}">${curve}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">US 2Y Prev</span><span class="risk-factor-value">${num(risk.yield_2y_prev, 2, true)}</span></div>
        </div>
    </div>`;
    return html;
}

/* ══════════════════════════════════════════════════
   GLOBAL MACRO ECONOMIC STATE (painel inferior da aba Risk Sentiment)
   ══════════════════════════════════════════════════ */
const MACRO_ECONOMY_ORDER = ['USA', 'EURO AREA', 'CHINA', 'JAPAN', 'BRAZIL'];
const MACRO_DIM_ORDER = ['growth', 'labor', 'inflation', 'financial_conditions', 'recession'];
const MACRO_DIM_LABEL = {
    growth: 'Growth', labor: 'Labor', inflation: 'Inflation',
    financial_conditions: 'Financial Conditions', recession: 'Recession Risk'
};

function macroScoreCls(s) {
    if (s === null || s === undefined) return 'neutral';
    return s > 0.1 ? 'risk-on' : (s < -0.1 ? 'risk-off' : 'neutral');
}
function macroRegimeCls(regime) {
    if (!regime) return 'neutral';
    if (/EXPANSION|HEALTHY|EARLY/i.test(regime)) return 'risk-on';
    if (/CONTRACTION|RECESSION|SLOWDOWN/i.test(regime)) return 'risk-off';
    return 'neutral';
}
function macroStateSig(macro) {
    if (!macro) return 'none';
    const g = (x) => (x === undefined || x === null) ? '' : x;
    let s = g(macro.generated_at) + '|';
    if (macro.global) {
        s += g(macro.global.regime) + '|' + g(macro.global.score) + '|';
        const d = macro.global.dimensions || {};
        for (const k of MACRO_DIM_ORDER) s += g(d[k] && d[k].score) + g(d[k] && d[k].state) + '|';
    }
    const ec = macro.economies || {};
    for (const e of MACRO_ECONOMY_ORDER) {
        const st = ec[e];
        if (!st) { s += e + ':MISSING|'; continue; }
        s += e + ':' + g(st.regime) + g(st.score) + g(st.data_quality) + '|';
        const d = st.dimensions || {};
        for (const k of MACRO_DIM_ORDER) {
            s += g(d[k] && d[k].score) + g(d[k] && d[k].state) + '|';
        }
    }
    return s;
}

function macroStateHtml(macro) {
    const empty = !macro || !macro.economies || Object.keys(macro.economies).length === 0;
    if (empty) {
        macro = macro || {};
        macro.economies = macro.economies || {};
        macro.global = macro.global || null;
    }
    const num = (x, d) => (x !== undefined && x !== null) ? Number(x).toFixed(d === undefined ? 2 : d) : '—';
    const pct = (sc) => (sc === undefined || sc === null || isNaN(sc)) ? '—' : String(Math.round((Number(sc) + 1) * 50));
    const dimRows = (dims) => {
        let r = '';
        for (const k of MACRO_DIM_ORDER) {
            const dv = (dims && dims[k]) || {};
            const sc = dv.score;
            let displayVal;
            if (k === 'recession' && sc !== null && sc !== undefined && !isNaN(sc)) {
                const prob = Math.max(0, Math.min(1, (1 - Number(sc)) / 2));
                displayVal = num(prob * 100, 0) + '%';
            } else {
                displayVal = pct(sc);
            }
            r += `<div class="risk-factor-row"><span class="risk-factor-label">${MACRO_DIM_LABEL[k]}</span>` +
                 `<span class="risk-factor-value ${macroScoreCls(sc)}">${displayVal}</span></div>`;
        }
        return r;
    };
    let cards = '';
    // Global card first (summary)
    if (macro.global) {
        const gl = macro.global;
        cards += `<div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">GLOBAL MACRO</span>
                <span class="macro-badge ${macroRegimeCls(gl.regime)}">${gl.regime || '—'}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">Macro Score</span>
                <span class="risk-factor-value ${macroScoreCls(gl.score)}">${pct(gl.score)}</span></div>
            ${dimRows(gl.dimensions)}
            ${gl.regime_confidence != null ? `<div class="risk-factor-row"><span class="risk-factor-label">Confidence</span><span class="risk-factor-value">${gl.regime_confidence}%</span></div>` : ''}
            ${gl.momentum ? `<div class="risk-factor-row"><span class="risk-factor-label">Momentum</span><span class="risk-factor-value ${gl.momentum === 'IMPROVING' ? 'positive' : gl.momentum === 'WEAKENING' ? 'negative' : ''}">${gl.momentum}</span></div>` : ''}
            ${gl.stability ? `<div class="risk-factor-row"><span class="risk-factor-label">Regime Stability</span><span class="risk-factor-value">${gl.stability}</span></div>` : ''}
        </div>`;
    } else {
        cards += `<div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">GLOBAL MACRO</span>
                <span class="macro-badge neutral">—</span></div>
            <div style="color:#777;font-size:11px;padding:14px">Resumo global indisponível.</div>
        </div>`;
    }
    const lastUpd = macro.generated_at ? macro.generated_at.replace('T', ' ').slice(0, 16) : '—';
    for (const e of MACRO_ECONOMY_ORDER) {
        const st = (macro.economies || {})[e];
        if (!st) {
            cards += `<div class="risk-card">
                <div class="risk-card-header"><span class="risk-card-title">${_flagBadge(e)} ${e}</span>
                    <span class="macro-badge neutral">NOT COMPUTED</span></div>
                <div style="color:#777;font-size:11px;padding:10px">Aguardando coleta do DataHouse (macro_series).</div>
            </div>`;
            continue;
        }
        const recProb = (st.recession_prob !== undefined && st.recession_prob !== null)
            ? `<div class="risk-factor-row"><span class="risk-factor-label">Recession Risk</span><span class="risk-factor-value ${macroScoreCls(-(st.recession_prob*2-1))}">${num(st.recession_prob * 100, 0)}%</span></div>` : '';
        const phil = (st.phillips_state) ? `<div class="risk-factor-row"><span class="risk-factor-label">Phillips Pressure</span><span class="risk-factor-value">${st.phillips_state}</span></div>` : '';
        const cov = st.coverage !== undefined && st.coverage !== null ? (st.coverage * 100).toFixed(0) + '%' : '—';
        const fresh = st.freshness !== undefined && st.freshness !== null ? (st.freshness * 100).toFixed(0) + '%' : '—';
        cards += `<div class="risk-card">
            <div class="risk-card-header"><span class="risk-card-title">${_flagBadge(e)} ${e}</span>
                <span class="macro-badge ${macroRegimeCls(st.regime)}">${st.regime || '—'}</span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">ECONOMIC REGIME</span>
                <span class="risk-factor-value">${st.regime || '—'}</span></div>
            ${st.regime_confidence != null ? `<div class="risk-factor-row"><span class="risk-factor-label">Confidence</span><span class="risk-factor-value">${st.regime_confidence}%</span></div>` : ''}
            ${st.momentum ? `<div class="risk-factor-row"><span class="risk-factor-label">Momentum</span><span class="risk-factor-value ${st.momentum === 'IMPROVING' ? 'positive' : st.momentum === 'WEAKENING' ? 'negative' : ''}">${st.momentum}</span></div>` : ''}
            ${st.stability ? `<div class="risk-factor-row"><span class="risk-factor-label">Regime Stability</span><span class="risk-factor-value">${st.stability}</span></div>` : ''}
            ${dimRows(st.dimensions)}
            <div class="risk-factor-row"><span class="risk-factor-label">Macro Score</span>
                <span class="risk-factor-value ${macroScoreCls(st.score)}">${pct(st.score)}</span></div>
            ${recProb}
            ${phil}
            <div class="risk-factor-row"><span class="risk-factor-label">Data Quality</span>
                <span class="risk-factor-value">${st.data_quality || '—'} <span style="font-size:8px;color:#888">Q:${cov} F:${fresh}</span></span></div>
            <div class="risk-factor-row"><span class="risk-factor-label">Last Update</span>
                <span class="risk-factor-value">${lastUpd}</span></div>
        </div>`;
    }
    const hint = empty ? `<div style="color:#888;font-size:10px;margin:4px 0 8px 2px">Dados do DataHouse (macro_series). Aguarde a coleta das séries macro pela rotina do DataHouse.</div>` : '';
    return `<div class="macro-state-section">
        <div class="macro-state-header">GLOBAL MACRO ECONOMIC STATE</div>
        ${hint}
        <div class="risk-grid">${cards}</div>
    </div>`;
}

/* ══════════════════════════════════════════════════
   NLP SENTIMENT TAB
   ══════════════════════════════════════════════════ */
function loadNlpSentimentTab() {
    const c = $('#tabNlpSentiment');
    if (!c) return;
    if (c.dataset.loaded === '1') return;
    c.dataset.loaded = '1';
    c.innerHTML = `
    <div class="asset-dna-controls">
        <div style="display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <button class="tf-btn active" onclick="runNlpSentiment()" id="nlpRunBtn">RUN SENTIMENT</button>
        </div>
        <div style="flex:1;display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <div style="color:#666;font-size:11px" id="nlpStatus">Click RUN to analyze news sentiment</div>
        </div>
    </div>

    <div class="asset-dna-reports" id="nlpSignalsPanel" style="flex:0 0 auto">
        <div class="asset-dna-reports-header">
            <span>SENTIMENT SIGNALS</span>
            <span style="color:#666" id="nlpSignalsCount"></span>
        </div>
        <div class="asset-dna-reports-body" id="nlpSignalsList">
            <div style="color:#666;padding:10px;text-align:center;font-size:12px">Loading signals...</div>
        </div>
    </div>

    <div class="asset-dna-reports" id="nlpMacroPanel" style="flex:0 0 auto">
        <div class="asset-dna-reports-header">
            <span>MACRO (USD / EUR / JPY / CNY)</span>
            <span style="color:#666" id="nlpMacroCount"></span>
        </div>
        <div class="asset-dna-reports-body" id="nlpMacroList">
            <div style="color:#666;padding:10px;text-align:center;font-size:12px">Loading macro sentiment...</div>
        </div>
    </div>

    <div class="asset-dna-reports" id="nlpNewsPanel">
        <div class="asset-dna-reports-header">
            <span>CLASSIFIED NEWS</span>
            <span style="color:#666" id="nlpNewsCount"></span>
        </div>
        <div class="asset-dna-reports-body" id="nlpNewsList">
            <div style="color:#666;padding:10px;text-align:center;font-size:12px">Loading news...</div>
        </div>
    </div>`;
    loadNlpSignals();
    loadNlpMacro();
    loadNlpNews();
}

async function loadNlpSignals() {
    const list = $('#nlpSignalsList');
    const count = $('#nlpSignalsCount');
    if (!list) return;
    const data = await api('/nlp/signals');
    const signals = (data && data.signals) || [];
    if (count) count.textContent = `${signals.length} assets`;
    if (!signals.length) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:12px">No signals yet — click RUN SENTIMENT</div>';
        return;
    }
    const fmt = (v) => v == null ? '-' : (v >= 0 ? '+' : '') + Number(v).toFixed(3);
    let html = '<table class="cal-table"><thead><tr><th>ATIVO</th><th>RAW</th><th>DECAYED</th><th>Z</th><th>NEWS</th><th>CONF</th><th>DIR</th><th>HIST</th></tr></thead><tbody>';
    for (const s of signals) {
        const dirClass = s.direction === 'bullish' ? 'nlp-dir-bullish' : s.direction === 'bearish' ? 'nlp-dir-bearish' : 'nlp-dir-neutral';
        html += `<tr>
            <td style="color:#ff9800;cursor:pointer" onclick="loadNlpHistory('${s.asset}')">${s.asset}</td>
            <td>${fmt(s.raw_score)}</td>
            <td>${fmt(s.decayed_score)}</td>
            <td>${s.z_score == null ? '-' : Number(s.z_score).toFixed(2)}</td>
            <td>${s.news_count}</td>
            <td>${(s.confidence * 100).toFixed(0)}%</td>
            <td class="${dirClass}">${s.direction.toUpperCase()}</td>
            <td><span id="nlpSpark_${s.asset}">…</span></td>
        </tr>`;
    }
    html += '</tbody></table>';
    list.innerHTML = html;
    for (const s of signals) loadNlpHistory(s.asset);
}

async function loadNlpHistory(asset) {
    const el = $('#nlpSpark_' + asset);
    if (!el) return;
    const data = await api('/nlp/history?asset=' + encodeURIComponent(asset) + '&days=7');
    el.innerHTML = renderNlpSparkline((data && data.series) || []);
}

function renderNlpSparkline(series) {
    if (!series || !series.length) return '<span style="color:#444">-</span>';
    const vals = series.map(p => Number(p.decayed_score));
    const min = Math.min(...vals, -1);
    const max = Math.max(...vals, 1);
    const w = 110, h = 26, pad = 2;
    const range = (max - min) || 1;
    const stepX = series.length > 1 ? (w - pad * 2) / (series.length - 1) : 0;
    const pts = series.map((p, i) => {
        const x = pad + (stepX ? i * stepX : w / 2);
        const y = h - pad - ((Number(p.decayed_score) - min) / range) * (h - pad * 2);
        return x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    const last = vals[vals.length - 1];
    const color = last > 0.02 ? '#4caf50' : last < -0.02 ? '#f44336' : '#888';
    return `<svg width="${w}" height="${h}" style="vertical-align:middle">
        <polyline points="${pts}" fill="none" stroke="${color}" stroke-width="1.5"/>
    </svg>`;
}

async function loadNlpNews() {
    const list = $('#nlpNewsList');
    const count = $('#nlpNewsCount');
    if (!list) return;
    const data = await api('/nlp/news');
    const news = (data && data.news) || [];
    if (count) count.textContent = `${news.length} items`;
    if (!news.length) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:12px">No classified news yet</div>';
        return;
    }
    let html = '';
    for (const n of news.slice(0, 60)) {
        const date = n.published_at ? new Date(n.published_at).toLocaleString('pt-BR') : '';
        let chips = '';
        (n.impacts || []).forEach(imp => {
            const d = (imp.direction || 'neutral').toLowerCase();
            const cls = d === 'bullish' ? 'nlp-dir-bullish' : d === 'bearish' ? 'nlp-dir-bearish' : 'nlp-dir-neutral';
            const sent = imp.sentiment == null ? '' : ' (' + (imp.sentiment >= 0 ? '+' : '') + Number(imp.sentiment).toFixed(2) + ')';
            chips += `<span class="nlp-impact-chip ${cls}">${imp.asset}${sent}</span>`;
        });
        const title = n.title || '(sem titulo)';
        const url = n.url || '#';
        html += `<div class="nlp-news-item">
            <div class="nlp-news-title"><a href="${url}" target="_blank" rel="noopener" style="color:#ff9800;text-decoration:none">${title}</a></div>
            <div class="nlp-news-meta">${n.source || ''} • ${date} • ${n.classifier_used || ''}</div>
            <div class="nlp-news-chips">${chips}</div>
        </div>`;
    }
    list.innerHTML = html;
}

async function loadNlpMacro() {
    const list = $('#nlpMacroList');
    const count = $('#nlpMacroCount');
    if (!list) return;
    const data = await api('/nlp/macro');
    const scores = (data && data.scores) || {};
    const entities = (data && data.entities) || Object.keys(scores);
    if (count) count.textContent = `${entities.length} economies`;
    if (!entities.length) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:12px">No macro data yet</div>';
        return;
    }
    const fmt = (v) => v == null ? '-' : (v >= 0 ? '+' : '') + Number(v).toFixed(3);
    let html = '<table class="cal-table"><thead><tr><th>ECONOMY</th><th>DECAYED</th><th>Z</th><th>NEWS</th><th>CONF</th><th>DIR</th><th>HIST</th></tr></thead><tbody>';
    for (const ent of entities) {
        const s = scores[ent] || { entity: ent, decayed_score: 0, z_score: 0, news_count: 0, confidence: 0, direction: 'neutral' };
        const dirClass = s.direction === 'bullish' ? 'nlp-dir-bullish' : s.direction === 'bearish' ? 'nlp-dir-bearish' : 'nlp-dir-neutral';
        html += `<tr>
            <td style="color:#ff9800">${ent}</td>
            <td>${fmt(s.decayed_score)}</td>
            <td>${s.z_score == null ? '-' : Number(s.z_score).toFixed(2)}</td>
            <td>${s.news_count}</td>
            <td>${(Number(s.confidence || 0) * 100).toFixed(0)}%</td>
            <td class="${dirClass}">${s.direction.toUpperCase()}</td>
            <td><span id="nlpMacroSpark_${ent}">…</span></td>
        </tr>`;
    }
    html += '</tbody></table>';
    list.innerHTML = html;
    for (const ent of entities) loadNlpMacroHistory(ent);
}

async function loadNlpMacroHistory(entity) {
    const el = $('#nlpMacroSpark_' + entity);
    if (!el) return;
    const data = await api('/nlp/macro/history?entity=' + encodeURIComponent(entity) + '&days=7');
    el.innerHTML = renderNlpSparkline((data && data.history) || []);
}

async function runNlpSentiment() {
    const btn = $('#nlpRunBtn');
    const status = $('#nlpStatus');
    if (btn) { btn.disabled = true; btn.textContent = 'ANALYZING...'; }
    if (status) status.textContent = 'Running NLP sentiment cycle (collect -> classify -> score)...';
    try {
        const res = await api('/nlp/run', 300000);
        if (res && res.ok) {
            const n = (res.signals || []).length;
            if (status) status.textContent = res.warning ? `AVISO: ${res.warning}` : `Done - ${n} asset(s) scored`;
            loadNlpSignals();
            loadNlpMacro();
            loadNlpNews();
        } else {
            if (status) status.textContent = 'FAILED: ' + (res ? res.error : 'no response');
        }
    } catch (e) {
        if (status) status.textContent = 'Error: ' + e.message;
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = 'RUN SENTIMENT'; }
    }
}

/* ══════════════════════════════════════════════════
   DATA MINER TAB
   ══════════════════════════════════════════════════ */
async function loadDataMinerTab() {
    const c = $('#tabDataMiner');
    if (!c) return;
    if (c.dataset.loaded === '1') return;
    c.dataset.loaded = '1';

    const res = await api('/dataminer/list');
    const files = (res && res.files) || [];

    let fileOptions = '<option value="">-- Select a CSV --</option>';
    files.forEach(f => {
        fileOptions += `<option value="${f.name}">${f.name} (${f.size_kb} KB)</option>`;
    });

    c.innerHTML = `
    <div class="dataminer-controls">
        <div style="display:flex;flex-direction:column;gap:4px">
            <label style="color:#666;font-size:9px;text-transform:uppercase">Miner CSV</label>
            <select class="asset-dna-select" id="minerFileSelect" onchange="onMinerFileChange(this.value)">
                ${fileOptions}
            </select>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <button class="tf-btn active" id="minerRunBtn" onclick="runDataMiner()" disabled>
                RUN ANALYSIS
            </button>
        </div>
        <div style="flex:1;color:#666;font-size:10px;padding:8px 0" id="minerStatus">
            ${files.length === 0 ? 'No miner CSV files found in data/mql5/' : 'Select a CSV file to analyze'}
        </div>
    </div>
    <div class="asset-dna-reports" id="minerReportsPanel">
        <div class="asset-dna-reports-header">
            <span>MINER REPORTS</span>
            <span style="color:#666" id="minerReportsCount"></span>
        </div>
        <div class="asset-dna-reports-body" id="minerReportsList">
            <div style="color:#666;padding:10px;text-align:center;font-size:10px">Loading reports...</div>
        </div>
    </div>
    <div class="dataminer-results" id="minerResults"></div>`;

    loadMinerReports();
}

async function loadMinerReports() {
    const list = $('#minerReportsList');
    const count = $('#minerReportsCount');
    if (!list) return;
    const data = await api('/dataminer/list');
    const pdfs = (data && data.pdfs) || [];
    if (count) count.textContent = `${pdfs.length} reports`;
    if (pdfs.length === 0) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:10px">No reports yet — run an analysis to generate one</div>';
        return;
    }
    let html = '<table class="asset-dna-reports-table"><thead><tr><th>ATIVO</th><th>DATA</th><th>TAM</th><th></th></tr></thead><tbody>';
    pdfs.forEach(p => {
        let dateStr = '';
        const src = p.generated_at || p.modified;
        if (src) {
            const d = new Date(src);
            if (!isNaN(d)) dateStr = d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', {hour:'2-digit',minute:'2-digit'});
        }
        const sym = p.symbol || p.name;
        const size = p.size_kb > 1024 ? (p.size_kb/1024).toFixed(1)+' MB' : p.size_kb+' KB';
        html += `<tr>
            <td style="cursor:pointer" onclick="openMinerReport('${p.name}')">${sym}</td>
            <td style="cursor:pointer" onclick="openMinerReport('${p.name}')">${dateStr}</td>
            <td style="cursor:pointer" onclick="openMinerReport('${p.name}')">${size}</td>
            <td><span class="dna-delete-btn" onclick="event.stopPropagation();deleteMinerReport('${p.name}')" title="Delete">&#128465;</span></td>
        </tr>`;
    });
    html += '</tbody></table>';
    list.innerHTML = html;
}

function openMinerReport(name) {
    const modal = $('#dnaViewerModal');
    const title = $('#dnaViewerTitle');
    const content = $('#dnaViewerContent');
    if (!modal || !content) return;
    title.textContent = `Miner Report — ${name}`;
    content.innerHTML = `<iframe src="/api/dataminer/pdf/${encodeURIComponent(name)}" style="width:100%;height:100%;border:none"></iframe>`;
    modal.classList.add('open');
}

async function deleteMinerReport(name) {
    if (!confirm(`Deletar relatório ${name}?`)) return;
    const res = await api(`/dataminer/delete/${encodeURIComponent(name)}`, 30000, 'DELETE');
    if (res && res.ok) {
        toast(`Relatório ${name} deletado`, 'info');
        loadMinerReports();
    } else {
        toast(`Falha ao deletar ${name}`, 'error');
    }
}

let _minerFileName = null;

function onMinerFileChange(name) {
    _minerFileName = name || null;
    const btn = $('#minerRunBtn');
    btn.disabled = !name;
    if (name) {
        const status = $('#minerStatus');
        status.textContent = `Selected: ${name}`;
        status.style.color = '#ff9800';
    }
}

async function runDataMiner() {
    if (!_minerFileName) return;
    const btn = $('#minerRunBtn');
    const status = $('#minerStatus');
    const results = $('#minerResults');

    btn.disabled = true;
    btn.textContent = 'RUNNING...';
    btn.style.opacity = '0.5';
    status.textContent = `Running Data Miner analysis on ${_minerFileName}...`;
    status.style.color = '#ff9800';

    const startTime = Date.now();
    const elapsedTimer = setInterval(() => {
        const secs = Math.floor((Date.now() - startTime) / 1000);
        status.textContent = `Running Data Miner analysis on ${_minerFileName}... ${secs}s`;
    }, 1000);

    const res = await api(`/dataminer/run?filename=${encodeURIComponent(_minerFileName)}`);
    clearInterval(elapsedTimer);

    btn.disabled = false;
    btn.textContent = 'RUN ANALYSIS';
    btn.style.opacity = '1';

    if (res && res.ok) {
        status.textContent = `✓ Analysis complete for ${_minerFileName}`;
        status.style.color = '#00ff88';
        toast(`Data Miner analysis complete`, 'info');
        _renderMinerResults(res);
        loadMinerReports();
    } else {
        const err = res?.error || res?.stderr || 'unknown error';
        status.textContent = `✗ Data Miner failed: ${err.slice(0, 150)}`;
        status.style.color = '#ff5252';
        toast(`Data Miner FAIL: ${err.slice(0, 100)}`, 'error');
    }
}

function _renderMinerResults(res) {
    const results = $('#minerResults');
    if (!results) return;

    const data = res.data || {};
    const basic = data.basic || {};
    const tailRisk = data.tail_risk || {};
    const bootstrap = data.bootstrap || {};

    results.innerHTML = `
    <div class="dataminer-section">
        <div class="dataminer-section-header">Performance Summary</div>
        <div class="dataminer-section-content">
            <div class="asset-dna-results">
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Total Trades</div>
                    <div class="asset-dna-metric-value">${basic.n_trades || '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Win Rate</div>
                    <div class="asset-dna-metric-value ${basic.win_rate > 55 ? 'positive' : basic.win_rate < 45 ? 'negative' : 'warning'}">${basic.win_rate ? basic.win_rate.toFixed(1) + '%' : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Avg R</div>
                    <div class="asset-dna-metric-value ${basic.avg_r > 0 ? 'positive' : 'negative'}">${basic.avg_r ? basic.avg_r.toFixed(3) : '—'}R</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Sharpe Annual</div>
                    <div class="asset-dna-metric-value">${basic.sharpe_annual ? basic.sharpe_annual.toFixed(2) : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Profit Factor</div>
                    <div class="asset-dna-metric-value ${basic.profit_factor > 1 ? 'positive' : 'negative'}">${basic.profit_factor ? basic.profit_factor.toFixed(2) : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Max Drawdown</div>
                    <div class="asset-dna-metric-value negative">${basic.max_drawdown_pct ? basic.max_drawdown_pct.toFixed(1) + '%' : '—'}</div>
                </div>
            </div>
        </div>
    </div>

    <div class="dataminer-section">
        <div class="dataminer-section-header">Tail Risk Analysis</div>
        <div class="dataminer-section-content">
            <div class="asset-dna-results">
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">CVaR 5%</div>
                    <div class="asset-dna-metric-value negative">${tailRisk.cvar_5 ? tailRisk.cvar_5.toFixed(3) + 'R' : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">CVaR 10%</div>
                    <div class="asset-dna-metric-value negative">${tailRisk.cvar_10 ? tailRisk.cvar_10.toFixed(3) + 'R' : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Skewness</div>
                    <div class="asset-dna-metric-value ${tailRisk.skewness < -0.5 ? 'negative' : 'positive'}">${tailRisk.skewness ? tailRisk.skewness.toFixed(3) : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Max Consecutive Losses</div>
                    <div class="asset-dna-metric-value ${tailRisk.max_consecutive_losses > 3 ? 'negative' : 'positive'}">${tailRisk.max_consecutive_losses || '—'}</div>
                </div>
            </div>
        </div>
    </div>

    <div class="dataminer-section">
        <div class="dataminer-section-header">Bootstrap Confidence Interval</div>
        <div class="dataminer-section-content">
            <div class="asset-dna-results">
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Mean R CI 95%</div>
                    <div class="asset-dna-metric-value">${bootstrap.mean_ci_low !== undefined ? bootstrap.mean_ci_low.toFixed(3) + 'R' : '—'} to ${bootstrap.mean_ci_high !== undefined ? bootstrap.mean_ci_high.toFixed(3) + 'R' : '—'}</div>
                </div>
                <div class="asset-dna-metric">
                    <div class="asset-dna-metric-label">Win Rate CI 95%</div>
                    <div class="asset-dna-metric-value">${bootstrap.wr_ci_low !== undefined ? bootstrap.wr_ci_low.toFixed(1) + '%' : '—'} to ${bootstrap.wr_ci_high !== undefined ? bootstrap.wr_ci_high.toFixed(1) + '%' : '—'}</div>
                </div>
            </div>
        </div>
    </div>`;
    results.classList.add('visible');
}

/* ══════════════════════════════════════════════════
   DB Status / System Metrics (Header)
   ══════════════════════════════════════════════════ */
let lastStatus = null;

let _statusSig = '';
async function loadStatus() {
    const data = await api('/status');
    if (!data) return;
    const sig = _sigOf(data);
    if (sig === _statusSig) return;
    _statusSig = sig;
    lastStatus = data;

    const summary = data.summary || {};
    const ds = summary.last_check ? 'OK' : 'ERR';
    document.querySelector('[data-key="db"]').textContent = 'DB ' + ds;
    document.querySelector('[data-key="db"]').className = 'market-item active';

    /* Update health indicator if visible */
    const healthEl = document.querySelector('[data-key="health"]');
    if (healthEl) {
        healthEl.textContent = 'HEALTH CHECKING...';
        healthEl.className = 'market-item active';
    }
}

/* ══════════════════════════════════════════════════
   Symbols / Watchlist
   ══════════════════════════════════════════════════ */
async function loadSymbols() {
    const data = await api('/symbols');
    if (!data) return;
    const tbody = $('#dhWatchlistBody');
    if (!tbody) return;
    const sig = _sigOf(data);
    if (!_changed(tbody, sig)) return;
    const countEl = $('#dhSymbolCount');
    if (countEl) countEl.textContent = data.length + ' symbols';

    const existing = {};
    Array.from(tbody.querySelectorAll('tr')).forEach(tr => { if (tr.dataset.symbol) existing[tr.dataset.symbol] = tr; });
    const seen = new Set();
    data.forEach(s => {
        seen.add(s.symbol);
        let tr = existing[s.symbol];
        if (!tr) { tr = document.createElement('tr'); tr.dataset.symbol = s.symbol; tbody.appendChild(tr); }
        tr.dataset.tf = s.timeframe;
        const age = s.age_hours || 0;
        const statusLabel = age < 24 ? 'OK' : (age < 168 ? 'STALE' : 'CRIT');
        const statusCls = age < 24 ? 'positive' : (age < 168 ? 'neutral' : 'negative');
        tr.innerHTML = `
            <td class="symbol">${s.symbol}</td>
            <td style="color:#666">${s.timeframe}</td>
            <td class="price">${s.last_close ? fmtPrice(s.last_close) : '—'}</td>
            <td style="color:#666">${age ? age.toFixed(0) + 'h' : '—'}</td>
            <td class="${statusCls}">${statusLabel}</td>
        `;
    });
    Array.from(tbody.querySelectorAll('tr')).forEach(tr => { if (tr.dataset.symbol && !seen.has(tr.dataset.symbol)) tr.remove(); });
}

/* ── Tasks (Datahouse) ── */
async function actionRegister() {
    toast('Registering tasks...', 'info');
    _logPush('INFO', 'Scheduler: registering tasks (user request)...');
    const r = await api('/schedules/register');
    if (r && r.messages) {
        r.messages.forEach(m => {
            toast(m, m.startsWith('OK') ? '' : 'error');
            const level = m.startsWith('OK') ? 'SCHED' : 'ERROR';
            _logPush(level, m);
        });
    }
    loadDatahouse();
}

async function actionRemove() {
    toast('Removing tasks...', 'info');
    _logPush('INFO', 'Scheduler: removing tasks (user request)...');
    const r = await api('/schedules/remove');
    if (r && r.messages) {
        r.messages.forEach(m => {
            toast(m, m.startsWith('Removed') ? '' : 'error');
            const level = m.startsWith('Removed') ? 'SCHED' : 'ERROR';
            _logPush(level, m);
        });
    }
    loadDatahouse();
}

/* ══════════════════════════════════════════════════
   Risk / Indices (Header Bar)
   ══════════════════════════════════════════════════ */
let _riskSig = '';
async function loadRisk() {
    const data = await api('/risk');
    if (!data) return;
    const sig = _sigOf(data);
    if (sig === _riskSig) return;
    _riskSig = sig;

    const keys = { vix: 'VIX', dxy: 'DXY', equity_sp: 'SPY', gold: 'GLD', yield_10y: '10Y' };
    Object.keys(keys).forEach(k => {
        const val = data[k];
        if (val === undefined || val === null) return;
        const el = $(`[data-key="${k}"]`);
        if (el) el.textContent = typeof val === 'number' ? val.toFixed(2) : val;
    });

    const chgKeys = ['vix', 'dxy', 'equity_sp', 'gold', 'yield_10y'];
    chgKeys.forEach(k => {
        const chg = data[`${k}_chg`];
        const chgPct = data[`${k}_chg_pct`];
        if (chg === undefined || chg === null) return;
        const el = $(`[data-key="${k}_chg"]`);
        if (!el) return;
        const sign = chg >= 0 ? '+' : '';
        el.textContent = `${sign}${chg.toFixed(2)} (${sign}${chgPct.toFixed(2)}%)`;
        el.className = 'index-change ' + (chg >= 0 ? 'positive' : 'negative');
    });

    const roro = data.roro_score;
    if (roro !== undefined) {
        const dbEl = $('[data-key="db_status"]');
        if (dbEl) dbEl.textContent = roro.toFixed(2);
        const roroChg = $('[data-key="db_status_chg"]');
        if (roroChg) {
            const label = data.risk_label || 'NEUTRAL';
            roroChg.textContent = label;
            roroChg.className = 'index-change ' + (label === 'RISK_OFF' ? 'negative' : label === 'RISK_ON' ? 'positive' : 'neutral');
        }
    }
}

/* ══════════════════════════════════════════════════
   Macro Economic (UNCHANGED)
   ══════════════════════════════════════════════════ */
const _FLAGS_STYLE = {
    us: { label: 'US', color: '#4a90d9' },
    eu: { label: 'EU', color: '#1a73e8' },
    cn: { label: 'CN', color: '#e53935' },
    jp: { label: 'JP', color: '#e91e63' },
    br: { label: 'BR', color: '#009c3b' },
    gb: { label: 'GB', color: '#012169' },
    ca: { label: 'CA', color: '#ff0000' },
    au: { label: 'AU', color: '#00008b' },
    ch: { label: 'CH', color: '#ff0000' },
    de: { label: 'DE', color: '#333333' }
};

function _flagBadge(country) {
    if (!country) return '<span style="color:#666">—</span>';
    const rawCode = String(country).trim().toLowerCase();
    const codeMap = {
        'united states': 'us', 'usa': 'us', 'estados unidos': 'us',
        'united kingdom': 'gb', 'uk': 'gb', 'reino unido': 'gb',
        'brazil': 'br', 'brasil': 'br',
        'germany': 'de', 'alemanha': 'de',
        'switzerland': 'ch', 'suica': 'ch', 'suíça': 'ch',
        'eurozone': 'eu', 'europa': 'eu',
        'japan': 'jp', 'japão': 'jp', 'japao': 'jp',
        'china': 'cn', 'china': 'cn',
    };
    const finalCode = codeMap[rawCode] || rawCode.substring(0, 2);
    const flagUrl = `https://flagcdn.com/w20/${finalCode}.png`;
    return `<img src="${flagUrl}" alt="${finalCode.toUpperCase()}" style="width:24px;height:16px;border-radius:3px;object-fit:cover;display:inline-block;vertical-align:middle" onerror="this.style.display='none'">`;
}

async function loadMacro() {
    const data = await api('/macro');
    if (!data) return;
    const tbody = $('#dhMacroBody');
    if (!tbody) return;
    const sig = _sigOf(data);
    if (!_changed(tbody, sig)) return;

    const esc = (s) => String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    const rows = [];
    data.forEach(m => {
        if (!m.symbol) return;
        const hay = ((m.description || '') + ' ' + (m.name || '')).toLowerCase();
        if (/remover|macro economic 0|placeholder|lixo/.test(hay)) return;
        rows.push(m);
    });

    const existing = {};
    Array.from(tbody.querySelectorAll('tr')).forEach(tr => { if (tr.dataset.sym) existing[tr.dataset.sym] = tr; });
    const seen = new Set();
    rows.forEach(m => {
        seen.add(m.symbol);
        const val = m.value !== null ? m.value.toFixed(2) : '—';
        const vCls = m.value !== null && m.value >= 0 ? 'positive' : 'negative';
        const badge = _flagBadge(m.country);
        const name = m.name || m.symbol;
        const unit = m.unit || '';
        const desc = m.description || name;
        let tr = existing[m.symbol];
        if (!tr) { tr = document.createElement('tr'); tr.dataset.sym = m.symbol; tbody.appendChild(tr); }
        tr.title = desc + (m.frequency ? ' — ' + m.frequency : '');
        tr.innerHTML = `
            <td style="width:60px;text-align:center">${badge}</td>
            <td class="symbol" style="white-space:nowrap">
                ${esc(name)}
                <span style="color:#555;font-size:9px;margin-left:4px">${esc(m.symbol)}</span>
            </td>
            <td class="price ${vCls}">${val}</td>
            <td style="color:#666;font-size:10px">${esc(unit)}</td>
        `;
    });
    Array.from(tbody.querySelectorAll('tr')).forEach(tr => { if (tr.dataset.sym && !seen.has(tr.dataset.sym)) tr.remove(); });

    if (data.length > 0 && data[0].date) {
        const d = $('#dhMacroDate'); if (d) d.textContent = data[0].date;
    }
}

/* ══════════════════════════════════════════════════
   Settings
   ══════════════════════════════════════════════════ */
async function loadSettings() {
    const data = await api('/settings');
    if (!data) return;
    const c = $('#settingsContent');
    const overlayData = await api('/settings/overlay');
    const autoRun = overlayData?.auto_run !== false;

    let html = `
    <div style="display:flex;gap:6px;margin-bottom:10px">
        <span class="tf-btn active" id="stabSys" onclick="switchSettingsTab('sys')">SYSTEM</span>
        <span class="tf-btn" id="stabMt5" onclick="switchSettingsTab('mt5')">MT5 CONNECTION</span>
        <span class="tf-btn" id="stabKeys" onclick="switchSettingsTab('keys')">API KEYS</span>
    </div>

    <div id="settingsSys">
    <table class="watchlist-table"><thead><tr><th>KEY</th><th>VALUE</th></tr></thead><tbody>`;
    Object.entries(data).forEach(([k, v]) => {
        if (k.startsWith('MT5_') || k === 'ENV_PATH' || k === 'KEYS') return;
        html += `<tr><td style="color:#ff9800">${k}</td><td style="font-family:'Courier New',monospace;font-size:11px">${v || '—'}</td></tr>`;
    });
    html += `</tbody></table>

    <div style="margin-top:12px;padding:8px;border:1px solid #222;border-radius:4px">
        <label class="dna-toggle" style="display:flex;align-items:center;gap:8px;cursor:pointer">
            <input type="checkbox" id="autoRunOverlay" ${autoRun ? 'checked' : ''} onchange="saveOverlaySetting(this.checked)">
            <span style="color:#81c784;font-weight:bold;font-size:11px">Auto-run Macro Overlay after profiler</span>
        </label>
        <div style="color:#666;font-size:10px;margin-top:4px">When enabled, Macro Overlay runs automatically after Asset DNA profiler completes</div>
    </div>
    </div>

    <div id="settingsMt5" style="display:none">
    <table class="watchlist-table"><thead><tr><th>FIELD</th><th>VALUE</th></tr></thead><tbody>
        <tr><td style="color:#ff9800">Path</td><td><input id="mt5Path" value="${escAttr(data.MT5_PATH || '')}" style="width:100%;background:#1a1a1a;border:1px solid #333;color:#e0e0e0;padding:4px 6px;font-size:11px;font-family:'Courier New',monospace"></td></tr>
        <tr><td style="color:#ff9800">Account</td><td><input id="mt5Account" value="${escAttr(data.MT5_ACCOUNT || '')}" style="width:100%;background:#1a1a1a;border:1px solid #333;color:#e0e0e0;padding:4px 6px;font-size:11px"></td></tr>
        <tr><td style="color:#ff9800">Password</td><td><input id="mt5Password" type="password" value="${data.MT5_PASSWORD_SET ? '********' : ''}" style="width:100%;background:#1a1a1a;border:1px solid ${data.MT5_PASSWORD_SET ? '#00ff88' : '#333'};color:#e0e0e0;padding:4px 6px;font-size:11px"></td></tr>
        <tr><td style="color:#ff9800">Server</td><td><input id="mt5Server" value="${escAttr(data.MT5_SERVER || '')}" style="width:100%;background:#1a1a1a;border:1px solid #333;color:#e0e0e0;padding:4px 6px;font-size:11px"></td></tr>
    </tbody></table>
    <div style="margin-top:10px;display:flex;gap:6px">
        <button class="tf-btn active" onclick="saveMt5()">SAVE</button>
        <button class="tf-btn" onclick="testMt5()">TEST CONNECTION</button>
    </div>
    <div id="mt5TestResult" style="margin-top:8px;font-size:11px;color:#666"></div>
    </div>

    <div id="settingsKeys" style="display:none">
    <table class="watchlist-table"><thead><tr><th>KEY</th><th>VALUE</th></tr></thead><tbody>
        ${(data.KEYS ? Object.entries(data.KEYS) : []).map(([k, set]) => `<tr><td style="color:#ff9800">${k}</td><td><input id="key_${k}" type="password" value="${set ? '********' : ''}" placeholder="paste ${k}" style="width:100%;background:#1a1a1a;border:1px solid #333;color:#e0e0e0;padding:4px 6px;font-size:11px;font-family:'Courier New',monospace"></td></tr>`).join('')}
    </tbody></table>
    <div style="margin-top:10px;display:flex;gap:6px">
        <button class="tf-btn active" onclick="saveApiKeys()">SAVE</button>
    </div>
    <div id="keysSaveResult" style="margin-top:8px;font-size:11px;color:#666"></div>
    </div>
    `;
    c.innerHTML = html;
}

function escAttr(s) {
    if (!s) return '';
    return String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function switchSettingsTab(tab) {
    $$('#settingsSys, #settingsMt5').forEach(el => el.style.display = 'none');
    $$('#stabSys, #stabMt5').forEach(el => el.classList.remove('active'));
    const map = { sys: 'settingsSys', mt5: 'settingsMt5', keys: 'settingsKeys' };
    const bmap = { sys: 'stabSys', mt5: 'stabMt5', keys: 'stabKeys' };
    $(`#${map[tab]}`).style.display = 'block';
    $(`#${bmap[tab]}`).classList.add('active');
}

async function saveOverlaySetting(autoRun) {
    try {
        await api('/settings/overlay', 10000, 'POST', { auto_run: autoRun });
        toast(`Auto-run overlay: ${autoRun ? 'ON' : 'OFF'}`, 'info');
    } catch (e) {
        toast('Failed to save overlay setting', 'error');
    }
}

async function saveMt5() {
    const body = {
        MT5_PATH: $('#mt5Path').value,
        MT5_ACCOUNT: $('#mt5Account').value,
        MT5_SERVER: $('#mt5Server').value,
    };
    const pw = $('#mt5Password').value;
    if (pw && pw !== '********') body.MT5_PASSWORD = pw;
    try {
        const r = await fetch('/api/settings/mt5', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
        const text = await r.text();
        let j;
        try { j = JSON.parse(text); } catch(e) { throw new Error(text.slice(0, 200)); }
        if (!r.ok) throw new Error(j.message || r.statusText);
        toast(j.message || 'Saved', j.status === 'saved' ? '' : 'error');
    } catch (e) {
        toast('Save failed: ' + e.message, 'error');
    }
}

async function testMt5() {
    const resultEl = $('#mt5TestResult');
    resultEl.textContent = 'Testing connection...';
    resultEl.style.color = '#ff9800';

    const pw = $('#mt5Password').value;
    const body = {
        MT5_PATH: $('#mt5Path').value,
        MT5_ACCOUNT: $('#mt5Account').value,
        MT5_SERVER: $('#mt5Server').value,
    };
    if (pw && pw !== '********') body.MT5_PASSWORD = pw;
    try {
        const r = await fetch('/api/settings/mt5/test', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
        const text = await r.text();
        let j;
        try { j = JSON.parse(text); } catch(e) { throw new Error(text.slice(0, 200)); }
        if (j.status === 'ok') {
            resultEl.innerHTML = `<span class="positive">✓ ${j.message}</span>`;
            resultEl.style.color = '#00ff88';
        } else {
            resultEl.innerHTML = `<span class="negative">✗ ${j.message}</span>`;
            resultEl.style.color = '#ff5252';
        }
    } catch (e) {
        resultEl.innerHTML = `<span class="negative">✗ ${e.message}</span>`;
        resultEl.style.color = '#ff5252';
    }
}

async function saveApiKeys() {
    const resultEl = $('#keysSaveResult');
    if (resultEl) { resultEl.textContent = 'Saving...'; resultEl.style.color = '#ff9800'; }
    const body = {};
    document.querySelectorAll('#settingsKeys input[id^="key_"]').forEach(inp => {
        const name = inp.id.replace(/^key_/, '');
        const val = inp.value;
        if (val && val !== '********') body[name] = val;
    });
    try {
        const r = await fetch('/api/settings/keys', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
        const text = await r.text();
        let j;
        try { j = JSON.parse(text); } catch(e) { throw new Error(text.slice(0, 200)); }
        if (!r.ok) throw new Error(j.message || r.statusText);
        if (resultEl) { resultEl.textContent = '✓ ' + (j.message || 'Saved'); resultEl.style.color = '#00ff88'; }
        toast(j.message || 'API keys saved', '');
    } catch (e) {
        if (resultEl) { resultEl.textContent = '✗ ' + e.message; resultEl.style.color = '#ff5252'; }
        toast('Save failed: ' + e.message, 'error');
    }
}

/* ══════════════════════════════════════════════════
   Data Health (Legacy - for backward compat)
   ══════════════════════════════════════════════════ */
let lastHealthData = null;

async function loadHealth() {
    const data = await api('/health');
    if (!data) return;
    lastHealthData = data;
    const dbEl = document.querySelector('[data-key="health"]');
    if (dbEl) {
        dbEl.textContent = 'HEALTH ' + (data.overall || 'unknown').toUpperCase();
        dbEl.className = 'market-item active';
    }
}

async function actionRepair(domain) {
    const pending = await api('/health/pending');
    const total = (pending && pending.total) || 0;
    if (domain === 'all' && total > 0) {
        const details = Object.entries(pending.domains || {})
            .filter(([, v]) => v.count > 0)
            .map(([d, v]) => `${d}: ${v.count}`)
            .join('\n');
        if (!confirm(`Start repair for ${total} item(s)?\n\n${details}\n\nThis will process up to 3 at a time.`)) {
            return;
        }
    }
    _doRepair(domain);
}

async function _doRepair(domain) {
    const label = domain === 'all' ? 'ALL DOMAINS' : domain;
    toast(`Repair started for ${label}...`, 'info');
    _logPush('INFO', `Repair: starting ${label} (user request)...`);
    try {
        const url = domain === 'all' ? '/api/health/repair' : `/api/health/repair/${domain}`;
        const r = await fetch(url, { method: 'POST' });
        const result = await r.json();
        toast(`${label}: ${result.status}`, result.status === 'started' ? '' : 'error');
        /* Refresh Datahouse if active */
        if (currentTab === 'datahouse') loadDatahouse();
    } catch (e) {
        toast(`Repair failed for ${label}: ${e.message}`, 'error');
    }
}

/* ══════════════════════════════════════════════════
   Execution Log (per-tab filtered)
   ══════════════════════════════════════════════════ */
let _logLastId = 0;
let _logTimer = null;
let _logReady = false;
let _logEntries = [];
let _dnaLogReady = false;
let _dnaLogLastId = 0;

const _TAB_LOG_FILTERS = {
    assetdna: (msg) => msg.includes('AssetDNA') || msg.includes('asset_dna') || msg.includes('ASSET DNA'),
    datahouse: (msg) => msg.includes('Scheduler') || msg.includes('Repair') || msg.includes('SCHED') || msg.includes('Auto-repair'),
    dataminer: (msg) => msg.includes('DataMiner') || msg.includes('miner'),
    checkfaqs: null,
};

function _logPush(level, message) {
    const now = new Date();
    const ts = now.toISOString().slice(11, 19);
    _appendLogRow({ id: 0, ts, level, message });
}

function _appendLogRow(entry) {
    const msg = entry.message || '';
    let lvlClass = entry.level === 'ERROR' ? 'log-error'
        : entry.level === 'WARNING' ? 'log-warning'
        : entry.level === 'SCHED' ? 'log-sched'
        : 'log-info';
    if (msg.includes('==== FASE') || msg.includes('==== PHASE')) {
        lvlClass = 'log-phase';
    } else if (msg.startsWith('[OK]') || msg.startsWith('[OK ')) {
        lvlClass = 'log-ok';
    } else if (msg.startsWith('[') && msg.includes(']') && msg.includes('...')) {
        lvlClass = 'log-step';
    }

    _logEntries.push({ ...entry, lvlClass });
    if (_logEntries.length > 500) _logEntries.shift();

    _renderToActiveTab(entry, lvlClass);
    _renderToDnaLog(entry, msg, lvlClass);
}

function _renderToActiveTab(entry, lvlClass) {
    const container = _getTabLogContainer(currentTab);
    if (!container) return;
    const row = document.createElement('div');
    row.className = 'time-sales-row';
    row.innerHTML = `<span style="color:#666">${entry.ts}</span><span class="${lvlClass}">${entry.message || ''}</span>`;
    if (container.firstChild) {
        container.insertBefore(row, container.firstChild);
    } else {
        container.appendChild(row);
    }
}

function _renderToDnaLog(entry, msg, lvlClass) {
    if (currentTab !== 'assetdna') return;
    const logBody = $('#dnaLogBody');
    if (!logBody) return;
    if (!_dnaLogReady) { logBody.innerHTML = ''; _dnaLogReady = true; }

    let dnaCls = 'log-info';
    if (msg.includes('FASE [') && msg.includes('--')) dnaCls = 'log-phase';
    else if (msg.includes('[OK]') || msg.includes('[OK ')) dnaCls = 'log-ok';
    else if (msg.includes('...') || msg.includes('starting')) dnaCls = 'log-step';
    else if (entry.level === 'ERROR') dnaCls = 'log-error';

    _parseDnaProgress(msg);

    const row = document.createElement('div');
    row.className = 'time-sales-row';
    row.innerHTML = `<span style="color:#666">${entry.ts}</span><span class="${dnaCls}">${msg}</span>`;
    if (logBody.firstChild) {
        logBody.insertBefore(row, logBody.firstChild);
    } else {
        logBody.appendChild(row);
    }
}

function _getTabLogContainer(tab) {
    if (tab === 'assetdna') return $('#dnaLogBody');
    return null;
}

function _parseDnaProgress(msg) {
    const m = msg.match(/FASE\s*\[(\d+)\/(\d+)\]/);
    if (!m) return;
    const cur = parseInt(m[1]);
    const total = parseInt(m[2]);
    const pct = Math.round((cur / total) * 100);
    const fill = $('#dnaProgressFill');
    const phase = $('#dnaLogPhase');
    if (fill) fill.style.width = pct + '%';
    if (phase) phase.textContent = `FASE [${cur}/${total}] ${pct}%`;
    const status = $('#dnaStatus');
    if (status && _assetDnaRunning) {
        status.textContent = `Running FASE ${cur}/${total} (${pct}%)`;
        status.style.color = '#ff9800';
    }
}

function renderActiveTabLog() {
    const container = _getTabLogContainer(currentTab);
    if (!container) return;
    container.innerHTML = '';
    const filter = _TAB_LOG_FILTERS[currentTab];
    const recent = _logEntries.slice(-100);
    /* Reverse: newest first (prepend) */
    for (let i = recent.length - 1; i >= 0; i--) {
        const entry = recent[i];
        const msg = entry.message || '';
        if (filter && !filter(msg)) continue;
        const row = document.createElement('div');
        row.className = 'time-sales-row';
        row.innerHTML = `<span style="color:#666">${entry.ts}</span><span class="${entry.lvlClass}">${msg}</span>`;
        container.appendChild(row);
    }
}

async function loadLogs() {
    if (_logLastId === 0) {
        const tailData = await api('/logs/tail?n=500');
        if (tailData && tailData.entries) {
            _logLastId = tailData.now || 0;
            tailData.entries.forEach(e => _appendLogRow(e));
        }
    }
    const data = await api('/logs?since=' + _logLastId);
    if (!data) return;
    _logLastId = data.now || _logLastId;
    if (data.entries && data.entries.length > 0) {
        data.entries.forEach(e => _appendLogRow(e));
    }
}

function startLogPolling() {
    if (_logTimer) clearInterval(_logTimer);
    loadLogs();
    _logTimer = setInterval(loadLogs, 2000);
}

/* ══════════════════════════════════════════════════
   EA CALIBRATOR TAB
   ══════════════════════════════════════════════════ */
async function loadCalibrationTab() {
    const c = $('#tabCalibration');
    if (!c) return;
    if (c.dataset.loaded === '1') return;
    c.dataset.loaded = '1';
    c.innerHTML = `
    <div class="asset-dna-controls">
        <div style="display:flex;flex-direction:column;gap:4px">
            <label style="color:#666;font-size:11px;text-transform:uppercase">Symbol</label>
            <select class="asset-dna-select" id="calSymbol"></select>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px">
            <label style="color:#666;font-size:11px;text-transform:uppercase">Timeframe</label>
            <select class="asset-dna-select" id="calTf">
                <option value="M5">M5</option>
                <option value="M15">M15</option>
                <option value="H1">H1</option>
                <option value="H4">H4</option>
            </select>
        </div>
        <div style="display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <button class="tf-btn active" onclick="runCalibration()" id="calRunBtn">RUN CALIBRATION</button>
        </div>
        <div style="flex:1;display:flex;flex-direction:column;gap:4px;justify-content:flex-end">
            <div style="color:#666;font-size:11px" id="calStatus">Select symbol and run calibration</div>
        </div>
    </div>

    <div class="asset-dna-reports" id="calReportsPanel">
        <div class="asset-dna-reports-header">
            <span>CALIBRATION REPORTS</span>
            <span style="color:#666" id="calReportsCount"></span>
        </div>
        <div class="asset-dna-reports-body" id="calReportsList">
            <div style="color:#666;padding:10px;text-align:center;font-size:12px">Loading reports...</div>
        </div>
    </div>

    <div class="calibration-results" id="calResults">
        <div style="color:#666;padding:20px;text-align:center;font-size:13px">
            Run calibration or click a report above to see suggestions
        </div>
    </div>`;
    _populateSymbolSelect('#calSymbol');
    loadCalibrationReports();
}

async function loadCalibrationReports() {
    const list = $('#calReportsList');
    const count = $('#calReportsCount');
    if (!list) return;
    const data = await api('/calibration/list');
    const files = (data && data.files) || [];
    const symbols = new Set();
    const rows = files.map(f => {
        symbols.add(f.symbol);
        let dateStr = '';
        const src = f.generated_at || f.modified;
        if (src) {
            const d = new Date(src);
            if (!isNaN(d)) dateStr = d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', {hour:'2-digit',minute:'2-digit'});
        }
        return { symbol: f.symbol, tf: f.tf, name: f.name, size: f.size_kb > 1024 ? (f.size_kb/1024).toFixed(1)+' MB' : f.size_kb+' KB', date: dateStr, modified: new Date(src || 0).getTime() };
    });
    rows.sort((a, b) => b.modified - a.modified);
    if (count) count.textContent = `${symbols.size} assets, ${rows.length} reports`;
    if (rows.length === 0) {
        list.innerHTML = '<div style="color:#666;padding:10px;text-align:center;font-size:10px">No reports yet — run calibration to generate one</div>';
        return;
    }
    let html = '<table class="asset-dna-reports-table"><thead><tr><th>ATIVO</th><th>TF</th><th>DATA</th><th>TAM</th><th></th></tr></thead><tbody>';
    for (const r of rows) {
        html += `<tr>
            <td style="cursor:pointer" onclick="openCalibrationReport('${r.symbol}','${r.tf}')">${r.symbol}</td>
            <td style="cursor:pointer" onclick="openCalibrationReport('${r.symbol}','${r.tf}')">${r.tf}</td>
            <td style="cursor:pointer" onclick="openCalibrationReport('${r.symbol}','${r.tf}')">${r.date}</td>
            <td style="cursor:pointer" onclick="openCalibrationReport('${r.symbol}','${r.tf}')">${r.size}</td>
            <td><span class="dna-delete-btn" onclick="event.stopPropagation();deleteCalibrationReport('${r.symbol}','${r.tf}')" title="Delete">&#128465;</span></td>
        </tr>`;
    }
    html += '</tbody></table>';
    list.innerHTML = html;
}

async function openCalibrationReport(symbol, tf) {
    const results = $('#calResults');
    const status = $('#calStatus');
    if (!results) return;
    results.innerHTML = '<div style="color:#ff9800;padding:20px;text-align:center;font-size:11px">Loading report...</div>';
    const res = await api(`/calibration/json/${symbol}?tf=${tf}`);
    if (res && res.ok && res.data) {
        _renderCalibrationResults(results, res.data);
        if (status) status.textContent = `Viewing ${symbol} ${tf}`;
    } else {
        const err = res?.error || 'failed to load report';
        results.innerHTML = `<div style="color:#fff;background:#b71c1c;padding:12px 16px;border-radius:4px;font-size:13px;margin:8px">ERROR: ${err}</div>`;
    }
}

async function deleteCalibrationReport(symbol, tf) {
    if (!confirm(`Deletar calibração de ${symbol} ${tf}?`)) return;
    const res = await api(`/calibration/delete/${symbol}?tf=${tf}`, 30000, 'DELETE');
    if (res && res.ok) {
        toast(`Calibração de ${symbol} ${tf} deletada`, 'info');
        loadCalibrationReports();
    } else {
        toast(`Falha ao deletar ${symbol} ${tf}`, 'error');
    }
}

async function runCalibration() {
    const sym = $('#calSymbol')?.value;
    const tf = $('#calTf')?.value || 'M5';
    const status = $('#calStatus');
    const results = $('#calResults');
    const btn = $('#calRunBtn');
    console.log('[CAL] runCalibration called', {sym, tf, results: !!results});
    if (!sym) { status.textContent = 'Select a symbol first'; return; }
    if (!results) { console.error('[CAL] #calResults not found'); return; }

    btn.disabled = true;
    btn.textContent = 'ANALYZING...';
    status.textContent = `Running calibration for ${sym} ${tf}...`;
    results.innerHTML = '<div style="color:#ff9800;padding:20px;text-align:center;font-size:13px">Agent is analyzing 3 data sources... (may take 30-60s)</div>';

    try {
        console.log('[CAL] Fetching API...');
        const res = await api(`/calibration/run?symbol=${sym}&tf=${tf}`, 300000);
        console.log('[CAL] API response:', res ? {ok: res.ok, hasData: !!res.data} : 'null');
        if (!res?.ok) {
            const errMsg = res?.error || 'Calibration failed — no response from server';
            status.textContent = 'FAILED';
            results.innerHTML = `<div style="color:#fff;background:#b71c1c;padding:12px 16px;border-radius:4px;font-size:13px;margin:8px">ERROR: ${errMsg}</div>`;
            return;
        }
        const count = res.data?.suggestions?.length || 0;
        status.textContent = `Done — ${count} suggestions`;
        console.log('[CAL] Rendering', count, 'suggestions');
        _renderCalibrationResults(results, res.data);
        loadCalibrationReports();
    } catch (e) {
        console.error('[CAL] Exception:', e);
        status.textContent = 'Error: ' + e.message;
        results.innerHTML = `<div style="color:#fff;background:#b71c1c;padding:12px 16px;border-radius:4px;font-size:13px;margin:8px">EXCEPTION: ${e.message}</div>`;
    } finally {
        btn.disabled = false;
        btn.textContent = 'RUN CALIBRATION';
    }
}

function _renderCalibrationResults(el, data) {
    console.log('[CAL] _renderCalibrationResults', {el: !!el, dataKeys: data ? Object.keys(data) : null});
    if (!data) { el.innerHTML = '<div style="color:#666;padding:20px">No data</div>'; return; }

    let html = '';

    /* Meta */
    const m = data.meta || {};
    html += `<div class="cal-section">
        <div class="cal-section-header">META</div>
        <div class="cal-section-body" style="font-size:12px;color:#888">
            Trades: ${m.dataminer_trades_analyzed || 0} | Provider: ${m.llm_provider || 'N/A'} | ${m.generated_at || ''}
            ${m.warning ? `<div style="color:#f44336;margin-top:4px">⚠ ${m.warning}</div>` : ''}
        </div>
    </div>`;

    /* Suggestions */
    const sugs = data.suggestions || [];
    if (sugs.length) {
        html += `<div class="cal-section"><div class="cal-section-header">SUGGESTIONS (${sugs.length})</div>
        <div class="cal-section-body"><table class="cal-table"><thead><tr>
            <th>PARAM</th><th>CURRENT</th><th>SUGGESTED</th><th>TYPE</th><th>CONF</th><th>REASONING</th>
        </tr></thead><tbody>`;
        sugs.forEach(s => {
            const tipo = s.tipo === 'ajuste_dentro_da_amostra' ? 'SAMPLE' : 'THEORETICAL';
            const confColor = s.confidence === 'high' ? '#4caf50' : s.confidence === 'medium' ? '#ffeb3b' : '#f44336';
            html += `<tr>
                <td style="color:#ff9800">${s.param}</td>
                <td>${s.current_value}</td>
                <td style="color:#4fc3f7">${s.suggested_value}</td>
                <td style="font-size:11px">${tipo}</td>
                <td style="color:${confColor}">${s.confidence.toUpperCase()}</td>
                <td style="font-size:11px;color:#888;max-width:300px">${s.reasoning}</td>
            </tr>`;
        });
        html += '</tbody></table></div></div>';
    }

    /* Divergences */
    const divs = data.divergences || [];
    if (divs.length) {
        html += `<div class="cal-section"><div class="cal-section-header">DIVERGENCES (${divs.length})</div>
        <div class="cal-section-body">`;
        divs.forEach(d => {
            html += `<div style="margin-bottom:8px;font-size:12px">
                <div style="color:#ff9800;font-weight:bold">${d.topic}</div>
                <div style="color:#4fc3f7">DNA: ${d.asset_dna_says}</div>
                <div style="color:#ccc">Miner: ${d.dataminer_says}</div>
                <div style="color:#888;font-style:italic">→ ${d.recommendation}</div>
            </div>`;
        });
        html += '</div></div>';
    }

    /* Insufficient evidence */
    const insuf = data.insufficient_evidence || [];
    if (insuf.length) {
        html += `<div class="cal-section"><div class="cal-section-header">INSUFFICIENT EVIDENCE (${insuf.length})</div>
        <div class="cal-section-body">`;
        insuf.forEach(e => {
            html += `<div style="font-size:12px;margin-bottom:4px">
                <span style="color:#f44336">${e.param}</span>: ${e.reason}
            </div>`;
        });
        html += '</div></div>';
    }

    el.innerHTML = html || '<div style="color:#666;padding:20px">No results</div>';
    console.log('[CAL] Rendered HTML length:', el.innerHTML.length);
}

/* ══════════════════════════════════════════════════
   Tab Event Listeners
   ══════════════════════════════════════════════════ */
$$('.tab-btn[data-tab]').forEach(btn => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
});

/* ══════════════════════════════════════════════════
   Keyboard Shortcuts
   ══════════════════════════════════════════════════ */
document.addEventListener('keydown', e => {
    if (e.key === 'r' || e.key === 'R') { if (!e.ctrlKey && !e.metaKey) actionRegister(); }
    if (e.key === 'u' || e.key === 'U') { if (!e.ctrlKey && !e.metaKey) actionRemove(); }
    if (e.key === 'h' || e.key === 'H') { if (!e.ctrlKey && !e.metaKey) { e.preventDefault(); actionRepair('all'); } }
});

/* ══════════════════════════════════════════════════
   Init
   ══════════════════════════════════════════════════ */
updateClock();
loadAll();
startLogPolling();
setInterval(loadAll, 30000);
// Check FAQs: refresh diário da tela (não reconstrói a aba, evita "piscar")
setInterval(() => { if (currentTab === 'checkfaqs') refreshCheckfaqs(); }, 24 * 60 * 60 * 1000);

/* Restore saved tab */
switchTab(currentTab);
