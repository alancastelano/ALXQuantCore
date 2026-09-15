import streamlit as st

from app.views.roro_view import render_roro_view
from app.views.regime_view import render_regime_view
from app.views.accounts_view import render_accounts_view
from app.views.config_view import render_config_view

st.set_page_config(
    page_title="ALXQuant Dashboard",
    page_icon="📊",
    layout="wide",
    initial_sidebar_state="expanded",
)

st.sidebar.markdown("## ALXQuant")
st.sidebar.markdown("Monitoramento Multi-Contas")
st.sidebar.markdown("---")

tab1, tab2, tab3, tab4 = st.tabs(["📊 RoRo", "📈 Regime", "🏦 Accounts", "⚙️ Config"])

with tab1:
    render_roro_view()

with tab2:
    render_regime_view()

with tab3:
    render_accounts_view()

with tab4:
    render_config_view()

st.sidebar.markdown("---")
st.sidebar.caption("v1.0 | ALXQuant Dashboard")
