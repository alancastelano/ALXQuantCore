// ALX Account Monitor — frontend v10.5
const API_BASE = '/api/v1';

function $(sel) { return document.querySelector(sel); }
function $$(sel) { return document.querySelectorAll(sel); }

function fmtNum(n) {
    const v = typeof n === 'string' ? parseFloat(n) : n;
    if (v === null || v === undefined || isNaN(v)) return '—';
    return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function fmtMoney(n) {
    const v = typeof n === 'string' ? parseFloat(n) : n;
    if (v === null || v === undefined || isNaN(v)) return '—';
    const sign = v > 0 ? '+' : '';
    return sign + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function fmtPrice(n) {
    const v = typeof n === 'string' ? parseFloat(n) : n;
    if (v === null || v === undefined || isNaN(v) || v === 0) return '—';
    return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 5 });
}

function cls(val) {
    const v = typeof val === 'string' ? parseFloat(val) : val;
    if (v === null || v === undefined || isNaN(v)) return '';
    return v > 0 ? 'pos-profit' : (v < 0 ? 'pos-loss' : '');
}

function toast(msg, type) {
    let c = document.querySelector('.toast-container');
    const t = document.createElement('div');
    t.className = 'toast ' + (type || '');
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => t.remove(), 4000);
}

function closeModal(id) { document.getElementById(id).classList.remove('open'); }

function updateClock() {
    const d = new Date();
    document.getElementById('headerDatetime').textContent =
        d.toISOString().slice(0, 19).replace('T', ' ') + ' UTC';
}
setInterval(updateClock, 1000);
updateClock();

// ==================== AUTH ====================

let sessionToken = localStorage.getItem('am_token');
let sessionRole = localStorage.getItem('am_role');
let sessionUser = localStorage.getItem('am_user');

function authHeaders() {
    return sessionToken ? { 'Authorization': 'Bearer ' + sessionToken } : {};
}

async function apiAuth(path, opts = {}) {
    const headers = Object.assign({}, authHeaders(), opts.headers || {});
    const r = await fetch(API_BASE + path, Object.assign({}, opts, { headers }));
    if (r.status === 401) {
        showLogin();
        throw new Error('session expired');
    }
    if (!r.ok) {
        const err = await r.json().catch(() => ({}));
        throw new Error(err.detail || err.error || 'HTTP ' + r.status);
    }
    return r.json();
}

async function handleLogin(e) {
    e.preventDefault();
    const user = $('#loginUser').value.trim();
    const pass = $('#loginPass').value;
    const btn = $('#loginBtn');
    const errEl = $('#loginError');

    btn.disabled = true;
    btn.textContent = 'LOGGING IN...';
    errEl.textContent = '';

    try {
        const r = await fetch(API_BASE + '/auth/login', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username: user, password: pass })
        });
        const data = await r.json();
        if (!r.ok) {
            errEl.textContent = data.error || data.detail || 'Login failed';
            return false;
        }
        sessionToken = data.token;
        sessionRole = data.role;
        sessionUser = data.username;
        localStorage.setItem('am_token', data.token);
        localStorage.setItem('am_role', data.role);
        localStorage.setItem('am_user', data.username);
        showDashboard();
    } catch (e) {
        errEl.textContent = 'Connection error';
    } finally {
        btn.disabled = false;
        btn.textContent = 'LOGIN';
    }
    return false;
}

function handleLogout() {
    if (sessionToken) {
        fetch(API_BASE + '/auth/logout', {
            method: 'POST',
            headers: authHeaders()
        }).catch(() => {});
    }
    sessionToken = null;
    sessionRole = null;
    sessionUser = null;
    localStorage.removeItem('am_token');
    localStorage.removeItem('am_role');
    localStorage.removeItem('am_user');
    showLogin();
}

function showLogin() {
    $('#loginScreen').style.display = 'flex';
    $('#dashboard').style.display = 'none';
    $('#loginUser').value = '';
    $('#loginPass').value = '';
    $('#loginError').textContent = '';
}

function showDashboard() {
    $('#loginScreen').style.display = 'none';
    $('#dashboard').style.display = 'flex';
    $('#userRoleBadge').textContent = (sessionRole || 'user').toUpperCase();
    $('#userName').textContent = sessionUser || '';
    if (sessionRole === 'admin') {
        $('#btnConfig').style.display = '';
    } else {
        $('#btnConfig').style.display = 'none';
    }
    initDashboard();
}

async function validateSession() {
    if (!sessionToken) { showLogin(); return; }
    try {
        const data = await apiAuth('/auth/me');
        sessionRole = data.role;
        sessionUser = data.username;
        localStorage.setItem('am_role', data.role);
        localStorage.setItem('am_user', data.username);
        showDashboard();
    } catch (e) {
        showLogin();
    }
}

// ==================== TABS ====================

let activeTab = localStorage.getItem('am_tab') || 'accounts';

function switchTab(tab) {
    activeTab = tab;
    localStorage.setItem('am_tab', tab);
    $$('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
    $('#tabAccounts').style.display = tab === 'accounts' ? '' : 'none';
    $('#tabPositions').style.display = tab === 'positions' ? '' : 'none';
    $('#tabAnalytics').style.display = tab === 'analytics' ? '' : 'none';
    $('#tabAlerts').style.display = tab === 'alerts' ? '' : 'none';
    if (tab === 'alerts') refreshAlerts();
    if (tab === 'analytics') refreshAnalytics();
}

// ==================== MODAL SUB-TABS ====================

let activeModalTab = 'performance';
let detailData = null;
let equityChart = null;

function switchModalTab(mtab) {
    activeModalTab = mtab;
    $$('.modal-tab').forEach(t => t.classList.toggle('active', t.dataset.mtab === mtab));
    renderDetailContent();
}

// ==================== CONFIG MODAL TABS ====================

function switchConfigTab(ctab) {
    $$('#configModal .modal-tab').forEach(t => t.classList.toggle('active', t.dataset.mtab === ctab));
    $('#configUsersSection').style.display = ctab === 'users' ? '' : 'none';
    $('#configTelegramSection').style.display = ctab === 'telegram' ? '' : 'none';
    if (ctab === 'telegram') loadTelegramConfig();
}

// ==================== DATA ====================

let lastSeenData = {};
let currentDetailAccount = null;
let pollInterval = null;

function statusClass(s) { return 'status status-' + (s || 'offline').toLowerCase(); }

function relSeen(ts) {
    if (!ts) return '—';
    const diff = (Date.now() / 1000) - ts;
    if (diff < 60) return Math.max(0, Math.round(diff)) + 's ago';
    if (diff < 3600) return Math.round(diff / 60) + 'm ago';
    return Math.round(diff / 3600) + 'h ago';
}

function renderAccounts(accounts) {
    const tbody = $('#accountsBody');
    tbody.innerHTML = '';
    $('#accountCount').textContent = accounts.length + ' accounts';
    const filterSel = $('#filterAccount');
    const cur = filterSel.value;
    filterSel.innerHTML = '<option value="">All Accounts</option>' +
        accounts.map(a => `<option value="${a.account_id}">${a.account_id}</option>`).join('');
    filterSel.value = cur;

    accounts.forEach(a => {
        const tr = document.createElement('tr');
        tr.innerHTML = `
            <td class="symbol">${a.account_id}</td>
            <td>${a.broker || a.server || '—'}</td>
            <td class="price">${fmtNum(a.balance)}</td>
            <td class="price">${fmtNum(a.equity)}</td>
            <td class="${cls(a.pnl_today)}">${fmtMoney(a.pnl_today)}</td>
            <td class="${cls(a.pnl_week)}">${fmtMoney(a.pnl_week)}</td>
            <td class="${cls(a.pnl_month)}">${fmtMoney(a.pnl_month)}</td>
            <td>${a.drawdown_today != null ? a.drawdown_today + '%' : '—'}</td>
            <td>${a.drawdown_pct != null ? a.drawdown_pct + '%' : '—'}</td>
            <td>${a.positions}</td>
            <td>${fmtNum(a.margin)}</td>
            <td><span class="${statusClass(a.status)}">${a.status}</span></td>
            <td>${relSeen(a.last_seen_ts)}</td>
            <td><span class="btn-delete" onclick="event.stopPropagation();deleteAccount('${a.account_id}')" title="Remover conta">&#128465;</span></td>`;
        tr.onclick = () => openDetail(a.account_id);
        tbody.appendChild(tr);
    });
}

function renderPositions(positions) {
    const tbody = $('#positionsBody');
    tbody.innerHTML = '';
    $('#posCount').textContent = positions.length + ' positions';

    const facct = $('#filterAccount').value;
    const ftype = $('#filterType').value;
    const fpnl = $('#filterPnl').value;

    positions.filter(p => {
        if (facct && p.account_id !== facct) return false;
        if (ftype && p.type !== ftype) return false;
        if (fpnl === 'profit' && (p.profit || 0) <= 0) return false;
        if (fpnl === 'loss' && (p.profit || 0) >= 0) return false;
        return true;
    }).forEach(p => {
        const tr = document.createElement('tr');
        const opentime = p.open_time ? new Date(p.open_time * 1000).toISOString().slice(0, 16).replace('T', ' ') : '—';
        tr.innerHTML = `
            <td class="symbol">${p.account_id}</td>
            <td class="symbol">${p.symbol}</td>
            <td>${p.type}</td>
            <td>${fmtNum(p.volume)}</td>
            <td class="price">${fmtPrice(p.open_price)}</td>
            <td class="price">${fmtPrice(p.current_price)}</td>
            <td class="price">${fmtPrice(p.sl)}</td>
            <td class="price">${fmtPrice(p.tp)}</td>
            <td class="${cls(p.profit)}">${fmtMoney(p.profit)}</td>
            <td class="${cls(p.swap)}">${fmtMoney(p.swap)}</td>
            <td class="${cls(p.commission)}">${fmtMoney(p.commission)}</td>
            <td>${p.magic || '—'}</td>
            <td>${opentime}</td>`;
        tbody.appendChild(tr);
    });
}

function renderSummary(s) {
    $('#kpiTotal').textContent = s.total_accounts ?? '—';
    $('#kpiOnline').textContent = s.online ?? '—';
    $('#kpiWarning').textContent = s.warning ?? '—';
    $('#kpiOffline').textContent = s.offline ?? '—';
    $('#kpiEquity').textContent = fmtNum(s.total_equity);
    $('#kpiToday').textContent = fmtMoney(s.total_pnl_today);
    $('#kpiToday').className = 'index-value ' + cls(s.total_pnl_today);
    $('#kpiWeek').textContent = fmtMoney(s.total_pnl_week);
    $('#kpiWeek').className = 'index-value ' + cls(s.total_pnl_week);
    $('#kpiMonth').textContent = fmtMoney(s.total_pnl_month);
    $('#kpiMonth').className = 'index-value ' + cls(s.total_pnl_month);
}

async function refreshAll() {
    if (!sessionToken) return;
    try {
        const [accts, summary] = await Promise.all([
            apiAuth('/accounts'),
            apiAuth('/dashboard/summary')
        ]);
        lastSeenData.accounts = accts.accounts || [];
        renderAccounts(lastSeenData.accounts);
        renderSummary(summary);
        await refreshPositions();
        if (activeTab === 'alerts') await refreshAlerts();
        if (activeTab === 'analytics') await refreshAnalytics();
    } catch (e) {
        if (e.message === 'session expired') return;
    }
}

async function refreshPositions() {
    if (!lastSeenData.accounts) return;
    const all = [];
    for (const a of lastSeenData.accounts) {
        try {
            const d = await apiAuth('/accounts/' + encodeURIComponent(a.account_id) + '/positions');
            for (const p of (d.positions || [])) {
                all.push(Object.assign({ account_id: a.account_id }, p));
            }
        } catch (e) {}
    }
    lastSeenData.positions = all;
    renderPositions(all);
}

// ==================== ALERTS ====================

async function refreshAlerts() {
    if (!sessionToken) return;
    try {
        const data = await apiAuth('/alerts');
        renderAlerts(data.alerts || []);
    } catch (e) {
        if (e.message === 'session expired') return;
    }
}

function renderAlerts(alerts) {
    const tbody = $('#alertsBody');
    const empty = $('#alertsEmpty');
    const filter = ($('#filterAlertType') || {}).value || '';
    const filtered = filter ? alerts.filter(a => a.alert_type === filter) : alerts;
    $('#alertCount').textContent = filtered.length + ' alerts';
    if (filtered.length === 0) {
        tbody.innerHTML = '';
        if (empty) empty.style.display = '';
        return;
    }
    if (empty) empty.style.display = 'none';
    const typeIcons = { offline: '🔴', warning: '⚠️', drawdown: '📉' };
    tbody.innerHTML = filtered.map(a => {
        const icon = typeIcons[a.alert_type] || '📌';
        const dt = a.sent_at ? a.sent_at.replace('T', ' ').substring(0, 19) : '—';
        const msg = (a.message || '').replace(/<[^>]+>/g, '').substring(0, 120);
        return `<tr>
            <td style="color:#888;white-space:nowrap">${dt}</td>
            <td style="color:#00ff88;font-family:monospace">${a.account_id || '—'}</td>
            <td>${icon} ${a.alert_type.toUpperCase()}</td>
            <td style="color:#aaa;max-width:400px;overflow:hidden;text-overflow:ellipsis">${msg}</td>
        </tr>`;
    }).join('');
}

// ==================== TELEGRAM CONFIG ====================

async function loadTelegramConfig() {
    try {
        const cfg = await apiAuth('/admin/telegram/config');
        $('#tgBotToken').value = cfg.bot_token || '';
        $('#tgChatId').value = cfg.chat_id || '';
        $('#tgEnabled').checked = !!cfg.enabled;
        $('#tgAlertOffline').checked = !!cfg.alert_offline;
        $('#tgAlertDD').checked = !!cfg.alert_drawdown;
        $('#tgDDThreshold').value = cfg.dd_threshold_pct || 10;
    } catch (e) {
        if (e.message === 'session expired') return;
        toast('Failed to load Telegram config', 'error');
    }
}

async function saveTelegramConfig() {
    try {
        const body = {
            bot_token: $('#tgBotToken').value.trim(),
            chat_id: $('#tgChatId').value.trim(),
            enabled: $('#tgEnabled').checked,
            alert_offline: $('#tgAlertOffline').checked,
            alert_drawdown: $('#tgAlertDD').checked,
            dd_threshold_pct: parseFloat($('#tgDDThreshold').value) || 10,
        };
        const r = await fetch(API_BASE + '/admin/telegram/config', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sessionToken },
            body: JSON.stringify(body),
        });
        if (!r.ok) {
            const err = await r.json().catch(() => ({}));
            toast('Error: ' + (err.detail || r.status), 'error');
            return;
        }
        toast('Telegram config saved', 'success');
    } catch (e) {
        toast('Failed to save config', 'error');
    }
}

async function testTelegram() {
    const resultEl = $('#tgTestResult');
    resultEl.textContent = 'Sending...';
    resultEl.className = 'tg-test-result';
    try {
        const r = await fetch(API_BASE + '/admin/telegram/test', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sessionToken },
            body: JSON.stringify({ message: 'Test from ALX Account Monitor' }),
        });
        if (!r.ok) {
            const err = await r.json().catch(() => ({}));
            resultEl.textContent = 'Failed: ' + (err.detail || r.status);
            resultEl.className = 'tg-test-result tg-test-error';
            return;
        }
        resultEl.textContent = 'Message sent successfully!';
        resultEl.className = 'tg-test-result tg-test-ok';
    } catch (e) {
        resultEl.textContent = 'Error: ' + e.message;
        resultEl.className = 'tg-test-result tg-test-error';
    }
}

// ==================== GLOBAL ANALYTICS ====================

let activeGlobalTab = 'summary';
let globalAnalyticsData = {};

function switchGlobalTab(tab) {
    activeGlobalTab = tab;
    $$('#tabAnalytics .modal-tab').forEach(t => t.classList.toggle('active', t.dataset.gtab === tab));
    renderGlobalAnalytics();
}

async function refreshAnalytics() {
    try {
        const [symbolsData, calData] = await Promise.all([
            apiAuth('/analytics/symbols').catch(() => ({ symbols: [] })),
            apiAuth('/analytics/calendar?year=' + new Date().getFullYear() + '&month=' + (new Date().getMonth() + 1)).catch(() => ({ days: [] }))
        ]);
        globalAnalyticsData.symbols = symbolsData.symbols || [];
        globalAnalyticsData.calendar = calData;
        renderGlobalAnalytics();
    } catch (e) { /* silent */ }
}

function renderGlobalAnalytics() {
    const body = $('#globalAnalyticsBody');
    if (!body) return;
    if (activeGlobalTab === 'summary') renderGlobalSummary(body);
    else renderGlobalCalendar(body);
}

function renderGlobalSummary(el) {
    const symbols = globalAnalyticsData.symbols || [];
    if (symbols.length === 0) {
        el.innerHTML = '<div style="text-align:center;color:#666;padding:32px">No trade data yet</div>';
        return;
    }
    let html = '<table class="watchlist-table"><thead><tr>';
    html += '<th>SYMBOL</th><th>ACCOUNTS</th><th>TRADES</th><th>LONGS</th><th>SHORTS</th>';
    html += '<th>WINS</th><th>LOSSES</th><th>WIN%</th><th>PROFIT</th><th>TOTAL WIN</th><th>TOTAL LOSS</th>';
    html += '</tr></thead><tbody>';
    html += symbols.map(s => `<tr>
        <td class="symbol">${s.symbol}</td>
        <td>${s.accounts}</td>
        <td>${s.trades}</td>
        <td>${s.longs}</td>
        <td>${s.shorts}</td>
        <td style="color:#00ff88">${s.wins}</td>
        <td style="color:#ff5252">${s.losses}</td>
        <td style="color:${s.win_pct >= 50 ? '#00ff88' : '#ff9800'}">${s.win_pct}%</td>
        <td class="${cls(s.profit)}">${fmtMoney(s.profit)}</td>
        <td style="color:#00ff88">${fmtMoney(s.total_win)}</td>
        <td style="color:#ff5252">${fmtMoney(s.total_loss)}</td>
    </tr>`).join('');
    const totTrades = symbols.reduce((a, s) => a + s.trades, 0);
    const totProfit = symbols.reduce((a, s) => a + s.profit, 0);
    const totWins = symbols.reduce((a, s) => a + s.wins, 0);
    html += `<tr style="font-weight:bold;border-top:2px solid #444">
        <td>TOTAL</td><td></td><td>${totTrades}</td><td></td><td></td>
        <td style="color:#00ff88">${totWins}</td><td></td>
        <td>${totTrades > 0 ? (totWins / totTrades * 100).toFixed(1) + '%' : '—'}</td>
        <td class="${cls(totProfit)}">${fmtMoney(totProfit)}</td><td></td><td></td>
    </tr>`;
    html += '</tbody></table>';
    el.innerHTML = html;
}

function renderGlobalCalendar(el) {
    const cal = globalAnalyticsData.calendar || {};
    const days = cal.days || [];
    const year = cal.year || new Date().getFullYear();
    const month = cal.month || (new Date().getMonth() + 1);
    const monthNames = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    const dayMap = {};
    days.forEach(d => { dayMap[d.day] = d; });
    const firstDay = new Date(year, month - 1, 1).getDay();
    const daysInMonth = new Date(year, month, 0).getDate();
    const dayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    let html = '<div style="text-align:center;margin-bottom:8px;font-size:13px;font-weight:bold;color:#aaa">' + monthNames[month - 1] + ' ' + year + '</div>';
    html += '<div class="cal-grid">';
    dayLabels.forEach(d => { html += `<div class="cal-header">${d}</div>`; });
    for (let i = 0; i < firstDay; i++) html += '<div class="cal-cell cal-empty"></div>';
    for (let day = 1; day <= daysInMonth; day++) {
        const key = year + '-' + String(month).padStart(2, '0') + '-' + String(day).padStart(2, '0');
        const data = dayMap[key];
        const pnl = data ? data.pnl : 0;
        const trades = data ? data.trades : 0;
        const losses = data ? data.losses : 0;
        const pnlColor = pnl > 0 ? '#00ff88' : pnl < 0 ? '#ff5252' : '#666';
        html += `<div class="cal-cell${trades > 0 ? ' cal-active' : ''}">
            <div class="cal-day">${day}</div>
            ${trades > 0 ? `<div class="cal-pnl" style="color:${pnlColor}">${fmtMoney(pnl)}</div>
            <div class="cal-trades">${trades} trades</div>
            ${losses > 0 ? `<div class="cal-losses">${losses} loss</div>` : ''}` : ''}
        </div>`;
    }
    html += '</div>';
    el.innerHTML = html;
}

// ==================== DETAIL MODAL ====================

async function openDetail(accountId) {
    currentDetailAccount = accountId;
    activeModalTab = 'performance';
    $$('.modal-tab').forEach(t => t.classList.toggle('active', t.dataset.mtab === 'performance'));
    try {
        const now = new Date();
        const [acctData, qualityData, symbolsData, wlData, calData, advData] = await Promise.all([
            apiAuth('/accounts/' + encodeURIComponent(accountId)),
            apiAuth('/accounts/' + encodeURIComponent(accountId) + '/quality').catch(() => ({ quality: [] })),
            apiAuth('/accounts/' + encodeURIComponent(accountId) + '/symbols').catch(() => ({ symbols: [] })),
            apiAuth('/accounts/' + encodeURIComponent(accountId) + '/winners-losers').catch(() => ({})),
            apiAuth('/accounts/' + encodeURIComponent(accountId) + '/calendar?year=' + now.getFullYear() + '&month=' + (now.getMonth() + 1)).catch(() => ({ days: [] })),
            apiAuth('/accounts/' + encodeURIComponent(accountId) + '/advanced-summary').catch(() => ({}))
        ]);
        detailData = acctData;
        detailData.quality = qualityData.quality || [];
        detailData.symbols = symbolsData.symbols || [];
        detailData.winnersLosers = wlData;
        detailData.calendar = calData;
        detailData.advancedSummary = advData.summary || {};
        detailData.monthlyGrid = advData.monthly_grid || {};
        detailData.durationAnalysis = advData.duration || {};
        detailData.overallMetrics = advData.overall || {};
        renderDetailContent();
        $('#detailTitle').textContent = 'ACCOUNT ' + accountId + ' — ' + (detailData.account.broker || detailData.account.server || '');
        document.getElementById('accountDetailModal').classList.add('open');
    } catch (e) {
        toast('Falha ao carregar conta ' + accountId, 'error');
    }
}

function renderDetailContent() {
    if (!detailData) return;
    const d = detailData;
    const a = d.account;
    const perf = d.performance || {};
    const stats = d.statistics || {};
    const curve = d.equity_curve || [];

    if (activeModalTab === 'performance') {
        // ACCOUNT INFO
        const cols = [
            ['BALANCE', a.balance], ['EQUITY', a.equity], ['MARGIN', a.margin],
            ['FREE MARGIN', a.free_margin], ['MARGIN LEVEL', a.margin_level],
            ['PROFIT', a.profit], ['CREDIT', a.credit], ['LEVERAGE', a.leverage]
        ];
        const infoHtml = '<div class="detail-section">' +
            '<div class="detail-subtitle">ACCOUNT INFO</div>' +
            '<div class="detail-kpi-row">' +
            cols.map(([k, v]) =>
                `<div class="detail-kpi"><div class="detail-kpi-label">${k}</div><div class="detail-kpi-value">${fmtNum(v)}</div></div>`
            ).join('') + '</div></div>';

        // P&L
        const perfHtml = '<div class="detail-section">' +
            '<div class="detail-subtitle">P&L</div>' +
            '<div class="detail-kpi-row">' +
            [['TODAY', perf.daily], ['WEEK', perf.weekly], ['MONTH', perf.monthly]].map(([k, v]) =>
                `<div class="detail-kpi"><div class="detail-kpi-label">${k}</div><div class="detail-kpi-value ${cls(v)}">${fmtMoney(v)}</div></div>`
            ).join('') +
            '</div></div>';

        // DRAWDOWN
        const ddHtml = '<div class="detail-section">' +
            '<div class="detail-subtitle">DRAWDOWN</div>' +
            '<div class="detail-kpi-row">' +
            [['DD TODAY', perf.drawdown_today], ['DD OVERALL', perf.drawdown_pct]].map(([k, v]) =>
                `<div class="detail-kpi"><div class="detail-kpi-label">${k}</div><div class="detail-kpi-value">${v != null ? v + '%' : '—'}</div></div>`
            ).join('') +
            '</div></div>';

        // STATISTICS
        const statKpis = [
            ['TOTAL TRADES', stats.total_trades],
            ['WIN RATE', stats.win_rate != null ? stats.win_rate + '%' : '—'],
            ['PROFIT FACTOR', stats.profit_factor],
            ['EXPECTANCY', stats.expectancy != null ? '$' + fmtNum(stats.expectancy) : '—'],
            ['AVG WIN', stats.avg_win != null ? '$' + fmtNum(stats.avg_win) : '—'],
            ['AVG LOSS', stats.avg_loss != null ? '$' + fmtNum(stats.avg_loss) : '—'],
            ['BEST TRADE', stats.best_trade != null ? '$' + fmtNum(stats.best_trade) : '—'],
            ['WORST TRADE', stats.worst_trade != null ? '$' + fmtNum(stats.worst_trade) : '—'],
            ['AVG R:R', stats.avg_rr],
        ];
        const statsHtml = '<div class="detail-section">' +
            '<div class="detail-subtitle">STATISTICS</div>' +
            '<div class="detail-kpi-row">' +
            statKpis.map(([k, v]) =>
                `<div class="detail-kpi"><div class="detail-kpi-label">${k}</div><div class="detail-kpi-value">${v != null ? v : '—'}</div></div>`
            ).join('') +
            '</div></div>';

        // EQUITY CURVE CHART
        const chartHtml = '<div class="detail-section">' +
            '<div class="detail-subtitle">EQUITY CURVE</div>' +
            '<div id="equityChartContainer" class="equity-chart-container"></div>' +
            '</div>';

        // OPEN POSITIONS
        let posHtml = '<div class="detail-section"><div class="detail-subtitle">OPEN POSITIONS</div>';
        if (d.positions && d.positions.length > 0) {
            posHtml += '<table class="watchlist-table"><thead><tr><th>Ticket</th><th>Symbol</th><th>Type</th><th>Volume</th><th>Open</th><th>Current</th><th>SL</th><th>TP</th><th>Profit</th></tr></thead><tbody>' +
                d.positions.map(p => `<tr>
                    <td>${p.ticket || '—'}</td>
                    <td class="symbol">${p.symbol || '—'}</td>
                    <td>${p.type || '—'}</td>
                    <td>${fmtNum(p.volume)}</td>
                    <td class="price">${fmtPrice(p.open_price)}</td>
                    <td class="price">${fmtPrice(p.current_price)}</td>
                    <td class="price">${fmtPrice(p.sl)}</td>
                    <td class="price">${fmtPrice(p.tp)}</td>
                    <td class="${cls(p.profit)}">${fmtMoney(p.profit)}</td>
                </tr>`).join('') +
                '</tbody></table>';
        } else {
            posHtml += '<div style="text-align:center;color:#666;padding:12px">No open positions</div>';
        }
        posHtml += '</div>';

        $('#detailBody').innerHTML = infoHtml + perfHtml + ddHtml + statsHtml + chartHtml + posHtml;

        // Renderizar grafico apos inserir no DOM
        requestAnimationFrame(() => renderEquityChart(curve));
    } else if (activeModalTab === 'summary') {
        // SUMMARY tab — Myfxbook Advanced Summary style
        const adv = d.advancedSummary || {};
        const symbols = adv.symbols || [];
        const overall = d.overallMetrics || {};
        const monthlyGrid = d.monthlyGrid || {};
        const duration = d.durationAnalysis || {};

        // --- Section 1: Overall Metrics ---
        let overallHtml = '<div class="detail-section"><div class="detail-subtitle">OVERALL PERFORMANCE</div>';
        overallHtml += '<div class="detail-kpi-row">';
        overallHtml += `<div class="detail-kpi"><div class="detail-kpi-label">GAIN</div><div class="detail-kpi-value ${cls(overall.gain_pct)}">${overall.gain_pct != null ? overall.gain_pct + '%' : '—'}</div></div>`;
        overallHtml += `<div class="detail-kpi"><div class="detail-kpi-label">ABS GAIN</div><div class="detail-kpi-value ${cls(overall.abs_gain)}">${fmtMoney(overall.abs_gain)}</div></div>`;
        overallHtml += `<div class="detail-kpi"><div class="detail-kpi-label">DAILY %</div><div class="detail-kpi-value ${cls(overall.daily_pct)}">${overall.daily_pct != null ? overall.daily_pct + '%' : '—'}</div></div>`;
        overallHtml += `<div class="detail-kpi"><div class="detail-kpi-label">MONTHLY %</div><div class="detail-kpi-value ${cls(overall.monthly_pct)}">${overall.monthly_pct != null ? overall.monthly_pct + '%' : '—'}</div></div>`;
        overallHtml += `<div class="detail-kpi"><div class="detail-kpi-label">INITIAL BALANCE</div><div class="detail-kpi-value">${fmtNum(overall.initial_balance)}</div></div>`;
        overallHtml += '</div></div>';

        // --- Section 2: Advanced Summary Matrix ---
        let matrixHtml = '<div class="detail-section"><div class="detail-subtitle">ADVANCED SUMMARY</div>';
        if (symbols.length > 0) {
            matrixHtml += '<div class="matrix-wrapper"><table class="matrix-table"><thead><tr>';
            matrixHtml += '<th class="matrix-header-symbol">PAIR</th>';
            const periods = ['floating', 'today', 'week', 'month', 'year', 'all'];
            const periodLabels = ['FLOATING', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'ALL'];
            periodLabels.forEach((label, i) => {
                matrixHtml += `<th colspan="3" class="matrix-header-period">${label}</th>`;
            });
            matrixHtml += '</tr><tr><th></th>';
            periodLabels.forEach(() => {
                matrixHtml += '<th class="matrix-sub">Gain</th><th class="matrix-sub">T</th><th class="matrix-sub">Win%</th>';
            });
            matrixHtml += '</tr></thead><tbody>';

            // Totals row data
            const totals = {};
            periods.forEach(p => { totals[p] = { gain: 0, trades: 0, wins: 0 }; });

            symbols.forEach(s => {
                matrixHtml += `<tr><td class="matrix-symbol">${s.symbol}</td>`;
                periods.forEach(p => {
                    const data = s[p] || { gain: 0, trades: 0, win_pct: 0 };
                    totals[p].gain += data.gain || 0;
                    totals[p].trades += data.trades || 0;
                    totals[p].wins += data.wins || 0;
                    matrixHtml += `<td class="${cls(data.gain)}">${fmtMoney(data.gain)}</td>`;
                    matrixHtml += `<td class="matrix-trades">${data.trades || 0}</td>`;
                    matrixHtml += `<td class="matrix-winpct" style="color:${(data.win_pct || 0) >= 50 ? '#00ff88' : '#ff9800'}">${data.win_pct || 0}%</td>`;
                });
                matrixHtml += '</tr>';
            });

            // Totals row
            matrixHtml += '<tr class="matrix-totals"><td>TOTAL</td>';
            periods.forEach(p => {
                const t = totals[p];
                const wp = t.trades > 0 ? (t.wins / t.trades * 100).toFixed(1) + '%' : '0%';
                matrixHtml += `<td class="${cls(t.gain)}">${fmtMoney(t.gain)}</td>`;
                matrixHtml += `<td class="matrix-trades">${t.trades}</td>`;
                matrixHtml += `<td class="matrix-winpct">${wp}</td>`;
            });
            matrixHtml += '</tr></tbody></table></div>';
        } else {
            matrixHtml += '<div style="text-align:center;color:#666;padding:16px">No trade data yet</div>';
        }
        matrixHtml += '</div>';

        // --- Section 3: Monthly Performance Grid ---
        const mgYears = monthlyGrid.years || [];
        let mgHtml = '<div class="detail-section"><div class="detail-subtitle">MONTHLY PERFORMANCE</div>';
        if (mgYears.length > 0) {
            const mLabels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            mgHtml += '<div class="matrix-wrapper"><table class="matrix-table monthly-grid"><thead><tr><th>YEAR</th>';
            mLabels.forEach(m => { mgHtml += `<th>${m}</th>`; });
            mgHtml += '<th class="matrix-total-col">TOTAL</th></tr></thead><tbody>';
            mgYears.forEach(yr => {
                mgHtml += `<tr><td class="matrix-symbol">${yr.year}</td>`;
                (yr.months || []).forEach(m => {
                    const color = m > 0 ? '#00ff88' : m < 0 ? '#ff5252' : '#666';
                    mgHtml += `<td style="color:${color};text-align:right">${m !== 0 ? (m > 0 ? '+' : '') + fmtNum(m) : '—'}</td>`;
                });
                const tColor = yr.total > 0 ? '#00ff88' : yr.total < 0 ? '#ff5252' : '#666';
                mgHtml += `<td class="matrix-total-col" style="color:${tColor};font-weight:bold">${yr.total > 0 ? '+' : ''}${fmtNum(yr.total)}</td>`;
                mgHtml += '</tr>';
            });
            mgHtml += '</tbody></table></div>';
        } else {
            mgHtml += '<div style="text-align:center;color:#666;padding:16px">No trade data yet</div>';
        }
        mgHtml += '</div>';

        // --- Section 4: Duration Analysis ---
        const buckets = duration.buckets || [];
        const avgDur = duration.avg_duration_sec || 0;
        let durHtml = '<div class="detail-section"><div class="detail-subtitle">DURATION ANALYSIS</div>';
        if (buckets.length > 0) {
            const maxCount = Math.max(...buckets.map(b => b.count), 1);
            durHtml += '<div class="duration-chart">';
            buckets.forEach(b => {
                const h = Math.max(2, Math.round((b.count / maxCount) * 120));
                const color = b.profit >= 0 ? '#00ff88' : '#ff5252';
                durHtml += `<div class="duration-bar-wrap">
                    <div class="duration-bar" style="height:${h}px;background:${color}"></div>
                    <div class="duration-label">${b.label}</div>
                    <div class="duration-count">${b.count}</div>
                    <div class="duration-profit ${cls(b.profit)}">${fmtMoney(b.profit)}</div>
                </div>`;
            });
            durHtml += '</div>';
            // Avg duration
            const hours = Math.floor(avgDur / 3600);
            const mins = Math.floor((avgDur % 3600) / 60);
            durHtml += `<div style="text-align:center;color:#aaa;margin-top:8px;font-size:12px">Avg. Trade Length: <b style="color:#00ff88">${hours}h ${mins}m</b></div>`;
        } else {
            durHtml += '<div style="text-align:center;color:#666;padding:16px">No trade data yet</div>';
        }
        durHtml += '</div>';

        // --- Section 5: Winners vs Losers (compact) ---
        const wl = d.winnersLosers || {};
        let wlHtml = '<div class="detail-section"><div class="detail-subtitle">WINNERS VS LOSERS</div><div class="detail-kpi-row">';
        wlHtml += `<div class="detail-kpi"><div class="detail-kpi-label">LONG WINS</div><div class="detail-kpi-value" style="color:#00ff88">${wl.long_wins || 0}</div></div>`;
        wlHtml += `<div class="detail-kpi"><div class="detail-kpi-label">LONG LOSSES</div><div class="detail-kpi-value" style="color:#ff5252">${wl.long_losses || 0}</div></div>`;
        wlHtml += `<div class="detail-kpi"><div class="detail-kpi-label">LONG PROFIT</div><div class="detail-kpi-value ${cls(wl.long_profit)}">${fmtMoney(wl.long_profit)}</div></div>`;
        wlHtml += `<div class="detail-kpi"><div class="detail-kpi-label">SHORT WINS</div><div class="detail-kpi-value" style="color:#00ff88">${wl.short_wins || 0}</div></div>`;
        wlHtml += `<div class="detail-kpi"><div class="detail-kpi-label">SHORT LOSSES</div><div class="detail-kpi-value" style="color:#ff5252">${wl.short_losses || 0}</div></div>`;
        wlHtml += `<div class="detail-kpi"><div class="detail-kpi-label">SHORT PROFIT</div><div class="detail-kpi-value ${cls(wl.short_profit)}">${fmtMoney(wl.short_profit)}</div></div>`;
        wlHtml += '</div></div>';

        $('#detailBody').innerHTML = overallHtml + matrixHtml + mgHtml + durHtml + wlHtml;

    } else if (activeModalTab === 'calendar') {
        // CALENDAR tab
        const cal = d.calendar || {};
        const days = cal.days || [];
        const year = cal.year || new Date().getFullYear();
        const month = cal.month || (new Date().getMonth() + 1);
        const monthNames = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

        // Build day map
        const dayMap = {};
        days.forEach(d => { dayMap[d.day] = d; });

        // Calendar grid
        const firstDay = new Date(year, month - 1, 1).getDay(); // 0=Sun
        const daysInMonth = new Date(year, month, 0).getDate();
        const dayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

        let calHtml = '<div class="detail-section"><div class="detail-subtitle">TRADE CALENDAR — ' + monthNames[month - 1] + ' ' + year + '</div>';
        calHtml += '<div class="cal-grid">';
        // Header
        dayLabels.forEach(d => { calHtml += `<div class="cal-header">${d}</div>`; });
        // Empty cells before first day
        for (let i = 0; i < firstDay; i++) calHtml += '<div class="cal-cell cal-empty"></div>';
        // Day cells
        for (let day = 1; day <= daysInMonth; day++) {
            const key = year + '-' + String(month).padStart(2, '0') + '-' + String(day).padStart(2, '0');
            const data = dayMap[key];
            const pnl = data ? data.pnl : 0;
            const trades = data ? data.trades : 0;
            const losses = data ? data.losses : 0;
            const pnlColor = pnl > 0 ? '#00ff88' : pnl < 0 ? '#ff5252' : '#666';
            calHtml += `<div class="cal-cell${trades > 0 ? ' cal-active' : ''}">
                <div class="cal-day">${day}</div>
                ${trades > 0 ? `<div class="cal-pnl" style="color:${pnlColor}">${fmtMoney(pnl)}</div>
                <div class="cal-trades">${trades} trades</div>
                ${losses > 0 ? `<div class="cal-losses">${losses} loss</div>` : ''}` : ''}
            </div>`;
        }
        calHtml += '</div></div>';
        $('#detailBody').innerHTML = calHtml;

    } else {
        // Quality Broker tab
        const totalSwap = (d.positions || []).reduce((s, p) => s + (p.swap || 0), 0);
        const totalComm = (d.positions || []).reduce((s, p) => s + (p.commission || 0), 0);
        const acct = d.account || {};
        const quality = d.quality || [];

        // Terminal Info
        const termHtml = `
            <div class="detail-section">
                <div class="detail-subtitle">TERMINAL INFO</div>
                <div class="detail-kpi-row">
                    <div class="detail-kpi"><div class="detail-kpi-label">BUILD</div><div class="detail-kpi-value">${acct.terminal_build || '—'}</div></div>
                    <div class="detail-kpi"><div class="detail-kpi-label">PING</div><div class="detail-kpi-value">${acct.terminal_ping_ms || '—'} ms</div></div>
                    <div class="detail-kpi"><div class="detail-kpi-label">STATUS</div><div class="detail-kpi-value" style="color:${acct.terminal_connected ? '#00ff88' : '#ff5252'}">${acct.terminal_connected ? 'CONNECTED' : 'DISCONNECTED'}</div></div>
                    <div class="detail-kpi"><div class="detail-kpi-label">VPS</div><div class="detail-kpi-value">${acct.vps_info || '—'}</div></div>
                </div>
            </div>`;

        // Quality per symbol
        let qualHtml = '<div class="detail-section"><div class="detail-subtitle">EXECUTION QUALITY</div>';
        if (quality.length > 0) {
            qualHtml += '<table class="watchlist-table"><thead><tr><th>SYMBOL</th><th>AVG SPREAD</th><th>MAX SPREAD</th><th>AVG SLIPPAGE</th><th>MAX SLIPPAGE</th><th>AVG LATENCY</th><th>MAX LATENCY</th><th>SUCCESS%</th><th>REQUESTS</th><th>SCORE</th><th>TOXIC</th></tr></thead><tbody>';
            qualHtml += quality.map(q => `<tr>
                <td class="symbol">${q.symbol || '—'}</td>
                <td>${q.avg_spread != null ? q.avg_spread.toFixed(1) : '—'}</td>
                <td>${q.max_spread != null ? q.max_spread.toFixed(1) : '—'}</td>
                <td>${q.avg_slippage != null ? q.avg_slippage.toFixed(1) : '—'}</td>
                <td>${q.max_slippage != null ? q.max_slippage.toFixed(1) : '—'}</td>
                <td>${q.avg_latency_ms != null ? Math.round(q.avg_latency_ms) + 'ms' : '—'}</td>
                <td>${q.max_latency_ms != null ? Math.round(q.max_latency_ms) + 'ms' : '—'}</td>
                <td style="color:${q.success_rate >= 95 ? '#00ff88' : q.success_rate >= 85 ? '#ff9800' : '#ff5252'}">${q.success_rate != null ? q.success_rate.toFixed(1) + '%' : '—'}</td>
                <td>${q.total_requests || 0}</td>
                <td style="color:${q.broker_score >= 80 ? '#00ff88' : q.broker_score >= 60 ? '#ff9800' : '#ff5252'}">${q.broker_score != null ? q.broker_score.toFixed(0) : '—'}</td>
                <td style="color:${q.is_toxic ? '#ff5252' : '#00ff88'}">${q.is_toxic ? 'YES' : 'NO'}</td>
            </tr>`).join('');
            qualHtml += '</tbody></table>';
        } else {
            qualHtml += '<div style="text-align:center;color:#666;padding:16px">No execution quality data yet.<br>Deploy CExecution with SaveQualityToFile() to start collecting data.</div>';
        }
        qualHtml += '</div>';

        // Swap + Commission
        const costHtml = `
            <div class="detail-section">
                <div class="detail-subtitle">COSTS</div>
                <div class="detail-kpi-row">
                    <div class="detail-kpi"><div class="detail-kpi-label">TOTAL SWAP</div><div class="detail-kpi-value ${cls(totalSwap)}">${fmtMoney(totalSwap)}</div></div>
                    <div class="detail-kpi"><div class="detail-kpi-label">TOTAL COMM</div><div class="detail-kpi-value ${cls(totalComm)}">${fmtMoney(totalComm)}</div></div>
                </div>
            </div>`;

        $('#detailBody').innerHTML = termHtml + qualHtml + costHtml;
    }
}

function renderEquityChart(data) {
    const container = document.getElementById('equityChartContainer');
    if (!container) return;

    // Destruir grafico anterior se existir
    if (equityChart) {
        equityChart.remove();
        equityChart = null;
    }

    if (!data || data.length === 0) {
        container.innerHTML = '<div style="text-align:center;color:#666;padding:20px">No equity data available</div>';
        return;
    }

    // Deduplicar por data (manter ultimo valor do dia)
    const seen = new Map();
    data.forEach(d => {
        seen.set(d.time, d.value);
    });
    const uniqueData = Array.from(seen.entries()).map(([time, value]) => ({ time, value }));

    equityChart = LightweightCharts.createChart(container, {
        width: container.clientWidth,
        height: 200,
        layout: {
            background: { type: 'solid', color: '#0d0d0d' },
            textColor: '#888',
            fontSize: 10,
        },
        grid: {
            vertLines: { color: '#1a1a1a' },
            horzLines: { color: '#1a1a1a' },
        },
        crosshair: {
            mode: LightweightCharts.CrosshairMode.Normal,
            vertLine: { color: '#333', width: 1, style: 0 },
            horzLine: { color: '#333', width: 1, style: 0 },
        },
        timeScale: {
            borderColor: '#333',
            timeVisible: false,
            rightOffset: 5,
        },
        rightPriceScale: {
            borderColor: '#333',
        },
    });

    const lineSeries = equityChart.addAreaSeries({
        topColor: 'rgba(0, 255, 136, 0.15)',
        bottomColor: 'rgba(0, 255, 136, 0.02)',
        lineColor: '#00ff88',
        lineWidth: 2,
        crosshairMarkerBackgroundColor: '#00ff88',
        crosshairMarkerBorderColor: '#000',
        priceFormat: { type: 'price', precision: 2, minMove: 0.01 },
    });

    lineSeries.setData(uniqueData);
    equityChart.timeScale().fitContent();

    // Resize observer
    const ro = new ResizeObserver(() => {
        if (equityChart && container.clientWidth > 0) {
            equityChart.applyOptions({ width: container.clientWidth });
        }
    });
    ro.observe(container);
}

// ==================== WEBSOCKET ====================

let ws = null;
let wsRetry = 1000;

function connectWs() {
    const proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
    ws = new WebSocket(proto + location.host + '/ws');

    ws.onopen = () => {
        wsRetry = 1000;
        $('#wsStatus').innerHTML =
            '<span class="market-item active" data-key="ws">WS — ON</span>' +
            '<span class="market-item active" data-key="conn">CONN — OK</span>';
    };

    ws.onmessage = (ev) => {
        try { JSON.parse(ev.data); } catch (e) { return; }
        refreshAll();
    };

    ws.onclose = () => {
        $('#wsStatus').innerHTML =
            '<span class="market-item" data-key="ws">WS — OFF</span>' +
            '<span class="market-item" data-key="conn">CONN — retry</span>';
        setTimeout(connectWs, wsRetry);
        wsRetry = Math.min(wsRetry * 2, 15000);
    };

    ws.onerror = () => { try { ws.close(); } catch (e) {} };
}

// ==================== ACCOUNT ACTIONS ====================

async function deleteAccount(accountId) {
    if (!confirm('Remover conta ' + accountId + '? Essa acao nao pode ser desfeita.')) return;
    try {
        const r = await apiAuth('/accounts/' + encodeURIComponent(accountId), { method: 'DELETE' });
        if (!r.ok) {
            const err = await r.json().catch(() => ({}));
            toast('Erro: ' + (err.detail || r.status), 'error');
            return;
        }
        toast('Conta ' + accountId + ' removida.', 'success');
        refreshAll();
    } catch (e) {
        toast('Falha ao remover conta', 'error');
    }
}

// ==================== CONFIG (ADMIN) ====================

async function openConfigModal() {
    if (sessionRole !== 'admin') { console.warn('openConfigModal: not admin, role=' + sessionRole); return; }
    const modal = document.getElementById('configModal');
    if (!modal) { console.error('configModal not found'); return; }
    modal.classList.add('open');
    console.log('openConfigModal: token=' + (sessionToken ? sessionToken.substring(0, 10) + '...' : 'null'));
    await loadUsers();
}

async function loadUsers() {
    const el = $('#usersList');
    if (!el) { console.error('usersList element not found'); return; }
    el.innerHTML = '<div style="color:#666;padding:8px">Loading users...</div>';
    try {
        const token = sessionToken || '';
        console.log('loadUsers: sending request, token=' + token.substring(0, 10) + '...');
        const r = await fetch(API_BASE + '/admin/users', { headers: { 'Authorization': 'Bearer ' + token } });
        console.log('loadUsers: response status=' + r.status);
        if (!r.ok) {
            const err = await r.json().catch(() => ({}));
            console.error('loadUsers: error', r.status, err);
            el.innerHTML = '<div style="color:#ff5252;padding:8px">Error ' + r.status + ': ' + (err.detail || 'failed') + '</div>';
            return;
        }
        const data = await r.json();
        const users = data.users || [];
        console.log('loadUsers: got ' + users.length + ' users');
        if (users.length === 0) {
            el.innerHTML = '<div style="color:#666;padding:8px">No users found</div>';
            return;
        }
        el.innerHTML = `<table class="users-table">
            <thead><tr><th>USERNAME</th><th>ROLE</th><th>LAST LOGIN</th><th>ACTIONS</th></tr></thead>
            <tbody>${users.map(u => {
            const isSelf = u.username === sessionUser;
            const roleOptions = ['admin', 'user'].map(r =>
                `<option value="${r}" ${u.role === r ? 'selected' : ''}>${r}</option>`
            ).join('');
            return `
            <tr class="user-row" id="userRow${u.id}">
                <td class="user-row-name">${u.username}</td>
                <td><select class="user-role-select role-${u.role}" ${isSelf ? 'disabled' : ''}
                    onchange="changeRole(${u.id}, this.value)">${roleOptions}</select>
                </td>
                <td class="user-row-date">${u.last_login ? u.last_login.slice(0, 16) : 'Never'}</td>
                <td class="user-actions">
                    ${!isSelf ? `<span class="btn-key" onclick="toggleResetPwd(${u.id})" title="Reset password">&#128273;</span>` : ''}
                    ${!isSelf ? `<span class="btn-delete" onclick="deleteUser(${u.id})" title="Delete">&#128465;</span>` : ''}
                </td>
            </tr>
            <tr class="reset-pwd-row" id="resetPwd${u.id}" style="display:none">
                <td colspan="4">
                    <input type="password" id="newPwd${u.id}" placeholder="New password (min 6 chars)" class="reset-pwd-input">
                    <button class="config-btn-sm" onclick="resetPassword(${u.id})">SET</button>
                    <button class="config-btn-cancel" onclick="toggleResetPwd(${u.id})">CANCEL</button>
                </td>
            </tr>`;
        }).join('')}</tbody></table>`;
    } catch (e) {
        console.error('loadUsers failed:', e);
        el.innerHTML = '<div style="color:#ff5252;padding:8px">Error: ' + e.message + '</div>';
    }
}

async function changeRole(userId, newRole) {
    if (!confirm('Change user role to ' + newRole + '?')) {
        await loadUsers();
        return;
    }
    try {
        await apiAuth('/admin/users/' + userId + '/role', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ role: newRole })
        });
        toast('Role updated', 'success');
        await loadUsers();
    } catch (e) {
        toast('Error: ' + e.message, 'error');
        await loadUsers();
    }
}

function toggleResetPwd(userId) {
    const el = document.getElementById('resetPwd' + userId);
    if (el) el.style.display = el.style.display === 'none' ? '' : 'none';
}

async function resetPassword(userId) {
    const input = document.getElementById('newPwd' + userId);
    const pwd = input ? input.value : '';
    if (pwd.length < 6) {
        toast('Password must be at least 6 characters', 'error');
        return;
    }
    try {
        await apiAuth('/admin/users/' + userId + '/password', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password: pwd })
        });
        toast('Password updated', 'success');
        toggleResetPwd(userId);
        if (input) input.value = '';
    } catch (e) {
        toast('Error: ' + e.message, 'error');
    }
}

async function createUser() {
    const username = $('#newUsername').value.trim();
    const password = $('#newPassword').value;
    const role = $('#newRole').value;

    if (!username || !password) {
        toast('Username and password required', 'error');
        return;
    }
    if (password.length < 6) {
        toast('Password must be at least 6 characters', 'error');
        return;
    }

    try {
        await apiAuth('/admin/users', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username, password, role })
        });
        toast('User ' + username + ' created', 'success');
        $('#newUsername').value = '';
        $('#newPassword').value = '';
        await loadUsers();
    } catch (e) {
        toast('Error: ' + e.message, 'error');
    }
}

async function deleteUser(userId) {
    if (!confirm('Delete this user?')) return;
    try {
        await apiAuth('/admin/users/' + userId, { method: 'DELETE' });
        toast('User deleted', 'success');
        await loadUsers();
    } catch (e) {
        toast('Error: ' + e.message, 'error');
    }
}

// ==================== FILTERS ====================

$('#filterAccount').addEventListener('change', refreshPositions);
$('#filterType').addEventListener('change', refreshPositions);
$('#filterPnl').addEventListener('change', refreshPositions);
$('#filterAlertType').addEventListener('change', refreshAlerts);

// ==================== INIT ====================

async function initDashboard() {
    // Version
    try {
        const v = await apiAuth('/version');
        $('#versionBadge').textContent = 'v' + v.version;
        const lv = document.getElementById('loginVersion');
        if (lv) lv.textContent = v.version;
    } catch (e) {}

    switchTab(activeTab);
    refreshAll();
    connectWs();
    if (pollInterval) clearInterval(pollInterval);
    pollInterval = setInterval(refreshAll, 10000);
}

// ==================== START ====================

// Version on login screen
fetch(API_BASE + '/version').then(r => r.json()).then(d => {
    const lv = document.getElementById('loginVersion');
    if (lv) lv.textContent = d.version;
}).catch(() => {});

validateSession();
