import re

file_path = r"C:\ALXQuant\app\asset_dna\profiler_v3_lite.py"

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Correção 1: WalkForwardValidator
old_wf = """    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[WALK-FORWARD] {self.n_windows} janelas...")
        dates = self.df.index.sort_values()
        if len(dates) < 10000:"""

new_wf = """    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[WALK-FORWARD] {self.n_windows} janelas...")
        # Detectar coluna de tempo (índice ou coluna 'time')
        if hasattr(self.df.index, 'strftime') or isinstance(self.df.index, pd.DatetimeIndex):
            time_col = self.df.index
        elif 'time' in self.df.columns:
            time_col = self.df['time']
        else:
            time_col = self.df.index
            
        dates = time_col.sort_values() if hasattr(time_col, 'sort_values') else time_col
        if len(dates) < 10000:"""

content = content.replace(old_wf, new_wf)

# Correção 2: Label do WalkForward
old_label_wf = """            periods.append({
                'label': f"{wdf.index[0].strftime('%Y-%m')} a {wdf.index[-1].strftime('%Y-%m')}\","""

new_label_wf = """            # Obter datas de início e fim da janela
            if 'time' in wdf.columns:
                start_date, end_date = wdf['time'].iloc[0], wdf['time'].iloc[-1]
            else:
                start_date, end_date = wdf.index[0], wdf.index[-1]
                
            periods.append({
                'label': f"{start_date.strftime('%Y-%m') if hasattr(start_date, 'strftime') else str(start_date)[:7]} a {end_date.strftime('%Y-%m') if hasattr(end_date, 'strftime') else str(end_date)[:7]}\","""

content = content.replace(old_label_wf, new_label_wf)


# Correção 3: PurgedWalkForwardValidator
old_pwf = """    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[PURGED WF] purge={self.purge_pct:.1%} embargo={self.embargo_pct:.1%}")
        n = len(self.df)"""

new_pwf = """    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[PURGED WF] purge={self.purge_pct:.1%} embargo={self.embargo_pct:.1%}")
        # Detectar coluna de tempo
        if hasattr(self.df.index, 'strftime') or isinstance(self.df.index, pd.DatetimeIndex):
            self._time_col = self.df.index
        elif 'time' in self.df.columns:
            self._time_col = self.df['time']
        else:
            self._time_col = self.df.index
        n = len(self.df)"""

content = content.replace(old_pwf, new_pwf)


# Correção 4: Label do Purged WF
old_label_pwf = """            periods.append({
                'label': f"J{i+1}", 'train_hurst': float(train_df['hurst'].mean()),"""

new_label_pwf = """            # Obter datas para o label
            if hasattr(self, '_time_col') and len(self._time_col) > test_end:
                tr_s = self._time_col.iloc[train_df.index[0]] if hasattr(self._time_col, 'iloc') else self._time_col[train_df.index[0]]
                tr_e = self._time_col.iloc[train_df.index[-1]] if hasattr(self._time_col, 'iloc') else self._time_col[train_df.index[-1]]
                te_s = self._time_col.iloc[test_df.index[0]] if hasattr(self._time_col, 'iloc') else self._time_col[test_df.index[0]]
                te_e = self._time_col.iloc[test_df.index[-1]] if hasattr(self._time_col, 'iloc') else self._time_col[test_df.index[-1]]
                lbl = f"J{i+1} ({tr_s.strftime('%Y-%m') if hasattr(tr_s, 'strftime') else str(tr_s)[:7]}->{te_e.strftime('%Y-%m') if hasattr(te_e, 'strftime') else str(te_e)[:7]})"
            else:
                lbl = f"J{i+1}"
                
            periods.append({
                'label': lbl, 'train_hurst': float(train_df['hurst'].mean()),"""

content = content.replace(old_label_pwf, new_label_pwf)


with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✅ Arquivo corrigido! O pipeline agora detecta a coluna de tempo automaticamente.")