param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# 必须在任何窗口创建前声明 DPI 感知: 否则高缩放比例下系统会把整个窗口位图拉伸, 字会发虚
try {
    Add-Type -Namespace PnlDpi -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    if (-not [PnlDpi.N]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [PnlDpi.N]::SetProcessDPIAware() | Out-Null }
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$code = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace OkxPnl
{
    public class Pos
    {
        public string InstId = "";
        public string Name = "--";
        public string Side = "";
        public double Size;
        public double AvgPx;
        public double MarkPx;
        public double Upl;
        public double Ratio;
        public double Lever;
        public double LiqPx;
        public string MgnMode = "cross";
    }

    public class Candle
    {
        public double O;
        public double H;
        public double L;
        public double C;
    }

    public class ApiKey
    {
        public string Key = "";
        public string Secret = "";
        public string Pass = "";
        public bool Demo = false;
        public bool NeedPass = true;      // 币安（U 本位合约）没有 Passphrase
        public bool Ready
        {
            get { return Key.Length > 8 && Secret.Length > 8 && (!NeedPass || Pass.Length > 0); }
        }
    }

    public class Board : Form
    {
        [DllImport("user32.dll")]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        private const int WM_HOTKEY = 0x0312;

        private List<Pos> _pos = new List<Pos>();
        private double _totalEq = 0;
        private double _upl = 0;

        // 旧的「每持仓迷你K线」已移除，K线统一由实时看盘提供
        private string _bar = "5m";

        private readonly object _lk = new object();

        private ApiKey _k = new ApiKey();                     // OKX
        private ApiKey _kb = new ApiKey();                    // 币安 U 本位合约（无 Passphrase）
        private string _ex = "okx";                           // okx | binance
        private ApiKey _ak { get { return _ex == "binance" ? _kb : _k; } }
        private static readonly string[] EX_IDS = new string[] { "okx", "binance" };
        private static readonly string[] EX_NAMES = new string[] { "OKX（统一账户）", "币安（U 本位合约）" };
        private string _dir;
        private string _cfgPath;

        private double _opacity = 0.95;
        private bool _autoDim = true;
        // 界面缩放系数: 100% DPI = 1.0, 125% = 1.25 ... 所有像素尺寸都乘它
        private float _s = 1f;
        private bool _glass = false;
        private int _interval = 1000;
        private bool _compact = true;
        private bool _mask = false;
        private bool _mouseIn = false;
        private bool _dragging = false;
        private bool _menuOpen = false;
        private int _x = -1;
        private int _y = -1;
        private string _proxy = "";

        private bool _outline = false;
        private bool _light = false;
        private bool _invert = false;      // 颜色反转：涨绿跌红
        private bool _autoText = true;        // 透明模式下按背景明暗自动切字色
        private bool _darkText = false;       // 当前是否用深色字（背景偏亮）
        private double _bgLum = 0.15;         // 平滑后的背景亮度 0~1
        private Timer _bgTimer;
        private KForm _chart;


        // 面板内的实时看盘：自选币对 + 迷你K线 + 现价/涨跌幅
        private bool _watch = true;
        private List<string> _watchSyms = new List<string>();
        private Dictionary<string, List<Candle>> _watchMap = new Dictionary<string, List<Candle>>();
        private Dictionary<string, double> _watchChgMap = new Dictionary<string, double>();
        private Dictionary<string, double> _watchLastMap = new Dictionary<string, double>();
        private bool _watchPrice = true;
        private int _watchKn = 5;          // 小 K 线根数
        private string _watchKBar = "";    // 小 K 线周期，空 = 跟随看盘周期
        private readonly HashSet<string> _watchInflight = new HashSet<string>();
        private Dictionary<string, DateTime> _watchFetchedAt = new Dictionary<string, DateTime>();
        private string _watchErr = "";

        private bool Configured
        {
            get { return _ak.Ready; }
        }

        // 主窗每次取到持仓就更新这份快照，K线窗拿它画「开/强平」线（K线窗自己不做签名）
        private static volatile List<Pos> _snap = new List<Pos>();
        public static List<Pos> SnapshotPositions()
        {
            List<Pos> s = _snap;
            return s == null ? new List<Pos>() : new List<Pos>(s);
        }

        private bool _tried = false;
        private bool _online = false;
        private string _lastErr = "";
        private bool _busy = false;

        private Point _downPt;
        private Point _startPt;

        private Font _fName;
        private Font _fNum;
        private Font _fTag;
        private Font _fSmall;

        private System.Threading.Timer _netTimer;
        private System.Windows.Forms.Timer _fadeTimer;
        private System.Windows.Forms.Timer _hideTimer;
        private ContextMenuStrip _menu;

        // 配色随主题切换：透明/深色用亮色，浅色卡片用深色
        private Color CU = Color.FromArgb(255, 92, 92);
        private Color CD = Color.FromArgb(56, 214, 146);
        private Color CF = Color.FromArgb(196, 200, 206);
        private Color CT = Color.FromArgb(248, 250, 252);
        private Color CLB = Color.FromArgb(214, 218, 224);
        private Color CName = Color.FromArgb(240, 232, 236, 242);   // 币种名
        private Color CChip = Color.FromArgb(210, 206, 211, 219);   // 看盘币种名（略暗）
        private Color CSub = Color.FromArgb(150, 148, 152, 160);    // @开仓价

        private void SetPalette()
        {
            if (_light || _darkText)
            {
                CU = Color.FromArgb(200, 40, 40);
                CD = Color.FromArgb(16, 138, 84);
                CF = Color.FromArgb(110, 116, 124);
                CT = Color.FromArgb(22, 24, 28);
                CLB = Color.FromArgb(52, 56, 64);
                CName = Color.FromArgb(24, 26, 30);
                CChip = Color.FromArgb(58, 62, 70);
                CSub = Color.FromArgb(96, 102, 110);
            }
            else
            {
                CU = Color.FromArgb(255, 92, 92);
                CD = Color.FromArgb(56, 214, 146);
                CF = Color.FromArgb(196, 200, 206);
                CT = Color.FromArgb(248, 250, 252);
                CLB = Color.FromArgb(214, 218, 224);
                CName = Color.FromArgb(240, 232, 236, 242);
                CChip = Color.FromArgb(210, 206, 211, 219);
                CSub = Color.FromArgb(242, 226, 230, 238);
            }

            // 颜色反转：涨绿跌红（K线实体、涨跌幅、盈亏一起换）
            if (_invert)
            {
                Color t = CU;
                CU = CD;
                CD = t;
            }
        }

        public Board(string dir)
        {
            _dir = dir;
            _cfgPath = Path.Combine(dir, "pnl-config.ini");

            // 先取屏幕 DPI: 高分屏上所有像素尺寸按比例放大, 否则字会被挤在几个像素里
            try
            {
                using (Graphics gs = Graphics.FromHwnd(IntPtr.Zero)) { _s = gs.DpiX / 96f; }
            }
            catch { _s = 1f; }
            if (_s < 1f) _s = 1f;
            if (_s > 3f) _s = 3f;

            _fName = new Font("Microsoft YaHei", 10f, FontStyle.Regular);
            _fNum = new Font("Consolas", 10.5f, FontStyle.Bold);
            _fTag = new Font("Microsoft YaHei", 11.5f, FontStyle.Bold);
            _fSmall = new Font("Consolas", 8f, FontStyle.Regular);

            LoadCfg();

            AutoScaleMode = AutoScaleMode.None;

            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            ShowInTaskbar = false;
            DoubleBuffered = true;
            Text = "pnl";
            Cursor = Cursors.SizeAll;

            ApplyChrome();
            BuildMenu();
            ContextMenuStrip = _menu;

            IntPtr h = this.Handle;

            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            if (_x < 0 || _y < 0 || _x > wa.Right - 60 || _y > wa.Bottom - 30)
            {
                _x = wa.Right - 230;
                _y = wa.Bottom - 120;
            }
            Location = new Point(_x, _y);

            Relayout();
            StartNet();

            _fadeTimer = new System.Windows.Forms.Timer();
            _fadeTimer.Interval = 40;
            _fadeTimer.Tick += new EventHandler(FadeTick);

            _bgTimer = new Timer();
            _bgTimer.Interval = 1500;
            _bgTimer.Tick += delegate { SampleBackground(); };
            _bgTimer.Start();
            _fadeTimer.Start();

            _hideTimer = new System.Windows.Forms.Timer();
            _hideTimer.Interval = 600000;
            _hideTimer.Tick += new EventHandler(HideTimerTick);

            MouseDown += new MouseEventHandler(OnDown);
            MouseMove += new MouseEventHandler(OnMove);
            MouseUp += new MouseEventHandler(OnUp);
            MouseEnter += new EventHandler(OnEnter);
            MouseLeave += new EventHandler(OnLeave);
            DoubleClick += new EventHandler(OnDouble);
            Resize += new EventHandler(OnResize2);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try { RegisterHotKey(this.Handle, 1, 0x2 | 0x1, 0x5A); } catch { }   // Ctrl+Alt+Z 悬浮窗 显示/隐藏
            try { RegisterHotKey(this.Handle, 2, 0x2 | 0x1, 0x51); } catch { }   // Ctrl+Alt+Q K线窗 显示/隐藏

        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == 1)
            {
                if (Visible) { Hide(); }
                else { Show(); TopMost = true; ApplyOpacity(_opacity); }
            }
            if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == 2) { ToggleChart(); }

            base.WndProc(ref m);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            try { UnregisterHotKey(this.Handle, 1); } catch { }
            try { UnregisterHotKey(this.Handle, 2); } catch { }
            if (_chart != null && !_chart.IsDisposed) { try { _chart.Close(); } catch { } }

            SaveCfg();

            if (_netTimer != null) _netTimer.Dispose();
            base.OnFormClosing(e);
        }

        private void ApplyChrome()
        {
            if (_light)
            {
                BackColor = Color.FromArgb(245, 246, 248);
                TransparencyKey = Color.Empty;
            }
            else if (_glass)
            {
                BackColor = Color.FromArgb(16, 17, 19);
                TransparencyKey = Color.Empty;
            }
            else
            {
                BackColor = Color.Black;
                TransparencyKey = Color.Black;
            }
            SetPalette();
        }

        /// <summary>透明模式下采样窗口外圈背景亮度，自动在深/浅字之间切换</summary>
        private void SampleBackground()
        {
            if (!_autoText || _light || _glass || !Visible) return;
            try
            {
                Rectangle b = Bounds;
                int m = 7 * (int)Math.Ceiling(_s);
                Rectangle r = new Rectangle(b.X - m, b.Y - m, b.Width + m * 2, b.Height + m * 2);
                if (r.Width <= 0 || r.Height <= 0) return;
                using (Bitmap bmp = new Bitmap(r.Width, r.Height))
                {
                    using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size);
                    double sum = 0;
                    int cnt = 0;
                    for (int x = 0; x < bmp.Width; x += 2)
                    {
                        for (int y = 0; y < bmp.Height; y += 2)
                        {
                            if (x >= m && x < bmp.Width - m && y >= m && y < bmp.Height - m) continue;
                            Color c = bmp.GetPixel(x, y);
                            sum += (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0;
                            cnt++;
                        }
                    }
                    if (cnt < 20) return;
                    double v = sum / cnt;
                    _bgLum = _bgLum * 0.55 + v * 0.45;
                    bool wantDark = _bgLum > 0.52;
                    if (wantDark != _darkText)
                    {
                        _darkText = wantDark;
                        SetPalette();
                        Invalidate();
                    }
                }
            }
            catch { }
        }

        private void ToggleGlass()
        {
            bool wasVisible = Visible;
            if (wasVisible) Hide();
            _glass = !_glass;
            ApplyChrome();
            Relayout();
            if (wasVisible) { Show(); TopMost = true; }
            else Invalidate();
            SaveCfg();
        }

        private void OnResize2(object s, EventArgs e)
        {
            if (_glass || _light)
            {
                using (GraphicsPath p = Rounded(new Rectangle(0, 0, Width, Height), 9))
                {
                    Region old = this.Region;
                    this.Region = new Region(p);
                    if (old != null) old.Dispose();
                }
            }
            else
            {
                Region old = this.Region;
                this.Region = null;
                if (old != null) old.Dispose();
            }
        }

        private static GraphicsPath Rounded(Rectangle r, int rad)
        {
            GraphicsPath p = new GraphicsPath();
            int d = rad * 2;
            if (r.Width <= d || r.Height <= d) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        private void ApplyOpacity(double v)
        {
            if (v < 0.05) v = 0.05;
            if (v > 1.0) v = 1.0;
            this.Opacity = v;
        }

        private double TargetOpacity()
        {
            if (_mouseIn || _dragging || _menuOpen || !_autoDim) return _opacity;
            // 旧版会淡到 30%, 在亮壁纸下基本看不见; 现在最低只淡到 75%, 且不低于 0.55
            return Math.Max(0.55, _opacity * 0.75);
        }

        private void FadeTick(object s, EventArgs e)
        {
            double t = TargetOpacity();
            double c = this.Opacity;
            if (Math.Abs(t - c) < 0.006) return;
            ApplyOpacity(c + (t - c) * 0.22);
        }

        private void OnEnter(object s, EventArgs e) { _mouseIn = true; }
        private void OnLeave(object s, EventArgs e) { _mouseIn = false; }

        private void OnDown(object s, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                _dragging = true;
                _downPt = Control.MousePosition;
                _startPt = Location;
            }
        }

        private void OnMove(object s, MouseEventArgs e)
        {
            if (_dragging)
            {
                Point p = Control.MousePosition;
                Location = new Point(_startPt.X + (p.X - _downPt.X), _startPt.Y + (p.Y - _downPt.Y));
            }
        }

        private void OnUp(object s, MouseEventArgs e)
        {
            if (_dragging)
            {
                _dragging = false;
                _x = Location.X;
                _y = Location.Y;
                SaveCfg();
            }
        }

        private void OnDouble(object s, EventArgs e)
        {
            _compact = !_compact;
            Relayout();
            SaveCfg();
        }

        private void HideTimerTick(object s, EventArgs e)
        {
            _hideTimer.Stop();
            Show();
            TopMost = true;
        }

        private void MenuHide10(object s, EventArgs e)
        {
            Hide();
            _hideTimer.Start();
        }

        private void ShowStatus()
        {
            StringBuilder s = new StringBuilder();
            s.AppendLine("交易所: " + (_ex == "binance" ? "币安（U 本位合约）" : "OKX"));
            s.AppendLine("API Key: " + (_ak.Ready ? "已配置" : "未配置"));
            s.AppendLine("模拟盘: " + (_ak.Demo ? "是" : "否"));
            s.AppendLine("代理: " + (_proxy.Length == 0 ? "(跟随系统代理)" : _proxy));
            s.AppendLine("连接: " + (_online ? "正常" : "异常"));
            s.AppendLine("持仓数: " + _pos.Count);
            s.AppendLine("权益: " + _totalEq.ToString("#,0.00", CultureInfo.InvariantCulture));
            if (_lastErr.Length > 0)
            {
                s.AppendLine();
                s.AppendLine("最近错误:");
                s.AppendLine(_lastErr);
            }
            MessageBox.Show(s.ToString(), "OKX 盈亏窗状态", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void BuildMenu()
        {
            _menu = new ContextMenuStrip();
            _menu.Font = new Font("Microsoft YaHei", 9f);
            _menu.Opened += delegate { _menuOpen = true; };
            _menu.Closed += delegate { _menuOpen = false; };

            ToolStripMenuItem miKey = new ToolStripMenuItem("填写 / 修改 API Key");
            miKey.Click += delegate { KeyDialog(); };
            _menu.Items.Add(miKey);

            ToolStripMenuItem miEx = new ToolStripMenuItem("交易所");
            for (int i = 0; i < EX_IDS.Length; i++)
            {
                string eid = EX_IDS[i];
                ToolStripMenuItem it = new ToolStripMenuItem(EX_NAMES[i]);
                it.Checked = (_ex == eid);
                it.Click += delegate
                {
                    _ex = eid;
                    SaveCfg();
                    _tried = false;
                    Relayout();
                    Invalidate();
                    if (!_ak.Ready) KeyDialog();
                    else FetchOnce();
                };
                miEx.DropDownItems.Add(it);
            }
            _menu.Items.Add(miEx);
            _menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem miGlass = new ToolStripMenuItem("半透明底板（方便拖拽）");
            miGlass.Checked = _glass;
            miGlass.Click += delegate
            {
                ToggleGlass();
                miGlass.Checked = _glass;
            };
            _menu.Items.Add(miGlass);

            ToolStripMenuItem miBar = new ToolStripMenuItem("看盘周期");
            string[] bars = new string[] { "1m", "5m", "15m", "1H", "4H", "1D" };
            string[] barNames = new string[] { "1 分钟", "5 分钟", "15 分钟", "1 小时", "4 小时", "1 天" };
            for (int i = 0; i < bars.Length; i++)
            {
                string bv = bars[i];
                ToolStripMenuItem it = new ToolStripMenuItem(barNames[i]);
                it.Click += delegate
                {
                    _bar = bv;
                    InvalidateWatch();
                    SaveCfg();
                    FetchWatch();
                    Relayout();
                    Invalidate();
                };
                miBar.DropDownItems.Add(it);
            }
            _menu.Items.Add(miBar);

            ToolStripMenuItem miMode = new ToolStripMenuItem("极简单行");
            miMode.Checked = _compact;
            miMode.Click += delegate
            {
                _compact = !_compact;
                miMode.Checked = _compact;
                Relayout();
                SaveCfg();
            };
            _menu.Items.Add(miMode);

            ToolStripMenuItem miMask = new ToolStripMenuItem("隐藏金额(只显示盈亏比例)");
            miMask.Checked = _mask;
            miMask.Click += delegate
            {
                _mask = !_mask;
                miMask.Checked = _mask;
                Relayout();
                SaveCfg();
            };
            _menu.Items.Add(miMask);

            ToolStripMenuItem miDim = new ToolStripMenuItem("闲置自动变淡");
            miDim.Checked = _autoDim;
            miDim.Click += delegate
            {
                _autoDim = !_autoDim;
                miDim.Checked = _autoDim;
                SaveCfg();
            };
            _menu.Items.Add(miDim);

            ToolStripMenuItem miAuto = new ToolStripMenuItem("文字跟随背景（透明模式）");
            miAuto.Checked = _autoText;
            miAuto.Click += delegate
            {
                _autoText = !_autoText;
                miAuto.Checked = _autoText;
                if (!_autoText && _darkText) { _darkText = false; SetPalette(); Invalidate(); }
                SaveCfg();
            };
            _menu.Items.Add(miAuto);

            ToolStripMenuItem miInvert = new ToolStripMenuItem("颜色反转（涨绿跌红）");
            miInvert.Checked = _invert;
            miInvert.Click += delegate
            {
                _invert = !_invert;
                miInvert.Checked = _invert;
                SetPalette();
                SaveCfg();
                Invalidate();
                // K线窗要重开才会用新配色
                if (_chart != null && !_chart.IsDisposed) { try { _chart.Close(); } catch { } _chart = null; }
            };
            _menu.Items.Add(miInvert);

            ToolStripMenuItem miLight = new ToolStripMenuItem("浅色卡片（深色字，最清楚）");
            miLight.Checked = _light;
            miLight.Click += delegate
            {
                _light = !_light;
                miLight.Checked = _light;
                bool vis = Visible;
                if (vis) Hide();
                ApplyChrome();
                Relayout();
                if (vis) { Show(); TopMost = true; }
                Invalidate();
                SaveCfg();
            };
            _menu.Items.Add(miLight);

            ToolStripMenuItem miOutline = new ToolStripMenuItem("数字描边（浅色壁纸更清楚）");
            miOutline.Checked = _outline;
            miOutline.Click += delegate
            {
                _outline = !_outline;
                miOutline.Checked = _outline;
                Invalidate();
                SaveCfg();
            };
            _menu.Items.Add(miOutline);

            ToolStripMenuItem miOp = new ToolStripMenuItem("文字浓度");
            double[] vals = new double[] { 0.75, 0.86, 0.95, 1.0 };
            string[] names = new string[] { "偏淡 75%", "正常 86%", "清晰 95%", "实心 100%" };
            for (int i = 0; i < vals.Length; i++)
            {
                double v = vals[i];
                ToolStripMenuItem it = new ToolStripMenuItem(names[i]);
                it.Click += delegate { _opacity = v; ApplyOpacity(v); SaveCfg(); };
                miOp.DropDownItems.Add(it);
            }
            _menu.Items.Add(miOp);

            ToolStripMenuItem miInt = new ToolStripMenuItem("刷新频率");
            int[] iv = new int[] { 1000, 2000, 3000, 5000, 10000, 30000 };
            string[] in2 = new string[] { "1 秒", "2 秒", "3 秒", "5 秒", "10 秒", "30 秒" };
            for (int i = 0; i < iv.Length; i++)
            {
                int v = iv[i];
                ToolStripMenuItem it = new ToolStripMenuItem(in2[i]);
                it.Click += delegate { _interval = v; StartNet(); SaveCfg(); };
                miInt.DropDownItems.Add(it);
            }
            _menu.Items.Add(miInt);

            _menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem miClose = new ToolStripMenuItem("一键平仓");
            miClose.DropDownOpening += delegate
            {
                miClose.DropDownItems.Clear();
                if (_pos.Count == 0)
                {
                    ToolStripMenuItem it0 = new ToolStripMenuItem("（当前无持仓）");
                    it0.Enabled = false;
                    miClose.DropDownItems.Add(it0);
                    return;
                }
                foreach (Pos p in _pos)
                {
                    Pos pp = p;
                    string side = (pp.Side == "short") ? "空" : (pp.Side == "long" ? "多" : "-");
                    ToolStripMenuItem it = new ToolStripMenuItem("平 " + pp.Name + " " + side
                        + "   量 " + pp.Size.ToString("0.####", CultureInfo.InvariantCulture)
                        + "   盈亏 " + Money(pp.Upl, true));
                    it.Click += delegate { ClosePosition(pp); };
                    miClose.DropDownItems.Add(it);
                }
            };
            _menu.Items.Add(miClose);

            ToolStripMenuItem miChart = new ToolStripMenuItem("K线窗（Ctrl+Alt+Q）");
            miChart.Click += delegate { ToggleChart(); };
            _menu.Items.Add(miChart);

            ToolStripMenuItem miWatch = new ToolStripMenuItem("实时看盘（面板内一行）");
            miWatch.Checked = _watch;
            miWatch.Click += delegate
            {
                _watch = !_watch;
                miWatch.Checked = _watch;
                if (_watch) { InvalidateWatch(); FetchWatch(); }
                SaveCfg();
                Relayout();
                Invalidate();
            };
            _menu.Items.Add(miWatch);

            ToolStripMenuItem miKn = new ToolStripMenuItem("小K线根数");
            int[] kns = new int[] { 3, 5, 8, 12, 16 };
            foreach (int kv in kns)
            {
                int kkn = kv;
                ToolStripMenuItem it = new ToolStripMenuItem(kkn + " 根");
                it.Checked = (kkn == _watchKn);
                it.Click += delegate
                {
                    _watchKn = kkn;
                    InvalidateWatch();
                    SaveCfg();
                    Relayout();
                    Invalidate();
                    FetchWatch();
                };
                miKn.DropDownItems.Add(it);
            }
            _menu.Items.Add(miKn);

            ToolStripMenuItem miKBar = new ToolStripMenuItem("小K线周期");
            ToolStripMenuItem follow = new ToolStripMenuItem("跟随看盘周期");
            follow.Checked = (_watchKBar.Length == 0);
            follow.Click += delegate
            {
                _watchKBar = "";
                InvalidateWatch();
                SaveCfg();
                FetchWatch();
            };
            miKBar.DropDownItems.Add(follow);
            miKBar.DropDownItems.Add(new ToolStripSeparator());
            string[] kbars = new string[] { "1m", "5m", "15m", "1H", "4H", "1D" };
            string[] kbarNames = new string[] { "1 分钟", "5 分钟", "15 分钟", "1 小时", "4 小时", "1 天" };
            for (int i = 0; i < kbars.Length; i++)
            {
                string bv = kbars[i];
                ToolStripMenuItem it = new ToolStripMenuItem(kbarNames[i]);
                it.Checked = (_watchKBar == bv);
                it.Click += delegate
                {
                    _watchKBar = bv;
                    InvalidateWatch();
                    SaveCfg();
                    FetchWatch();
                };
                miKBar.DropDownItems.Add(it);
            }
            _menu.Items.Add(miKBar);

            ToolStripMenuItem miWatchPx = new ToolStripMenuItem("看盘显示价格");
            miWatchPx.Checked = _watchPrice;
            miWatchPx.Click += delegate
            {
                _watchPrice = !_watchPrice;
                miWatchPx.Checked = _watchPrice;
                SaveCfg();
                Relayout();
                Invalidate();
            };
            _menu.Items.Add(miWatchPx);

            ToolStripMenuItem miWatchAdd = new ToolStripMenuItem("添加看盘币对…");
            miWatchAdd.Click += delegate { WatchDialog(); };
            _menu.Items.Add(miWatchAdd);

            ToolStripMenuItem miWatchSym = new ToolStripMenuItem("看盘币对");
            miWatchSym.DropDownOpening += delegate
            {
                miWatchSym.DropDownItems.Clear();
                foreach (string id in WatchSymbols())
                {
                    string sid = id;
                    ToolStripMenuItem it = new ToolStripMenuItem(Short(id));
                    it.Checked = _watchSyms.Contains(sid);
                    it.Click += delegate
                    {
                        it.Checked = !it.Checked;
                        if (it.Checked)
                        {
                            if (_watchSyms.Count >= 6) { it.Checked = false; return; }
                            if (!_watchSyms.Contains(sid)) _watchSyms.Add(sid);
                        }
                        else
                        {
                            _watchSyms.Remove(sid);
                        }
                        InvalidateWatch();
                        _watch = true;
                        miWatch.Checked = true;
                        SaveCfg();
                        FetchWatch();
                        Relayout();
                        Invalidate();
                    };
                    miWatchSym.DropDownItems.Add(it);
                }
                miWatchSym.DropDownItems.Add(new ToolStripSeparator());
                ToolStripMenuItem diy = new ToolStripMenuItem("自定义币对…");
                diy.Click += delegate { WatchDialog(); };
                miWatchSym.DropDownItems.Add(diy);
            };
            _menu.Items.Add(miWatchSym);

            ToolStripMenuItem miRef = new ToolStripMenuItem("立即刷新");
            miRef.Click += delegate { FetchOnce(); };
            _menu.Items.Add(miRef);

            ToolStripMenuItem miSt = new ToolStripMenuItem("查看连接状态");
            miSt.Click += delegate { ShowStatus(); };
            _menu.Items.Add(miSt);

            ToolStripMenuItem miHide = new ToolStripMenuItem("隐藏 10 分钟");
            miHide.Click += new EventHandler(MenuHide10);
            _menu.Items.Add(miHide);

            ToolStripMenuItem miQuit = new ToolStripMenuItem("退出");
            miQuit.Click += delegate { Close(); };
            _menu.Items.Add(miQuit);
        }

        private void KeyDialog()
        {
            Form d = new Form();
            d.Text = "API Key";
            d.FormBorderStyle = FormBorderStyle.FixedDialog;
            d.StartPosition = FormStartPosition.CenterScreen;
            d.MaximizeBox = false;
            d.MinimizeBox = false;
            d.ClientSize = new Size(560, 470);
            d.TopMost = true;
            d.Font = new Font("Microsoft YaHei", 10f);

            d.Controls.Add(MkLabel("交易所", 16, 14));
            ComboBox cbEx = new ComboBox();
            cbEx.DropDownStyle = ComboBoxStyle.DropDownList;
            cbEx.Font = new Font("Microsoft YaHei", 10f);
            cbEx.SetBounds(118, 10, 240, 28);
            foreach (string n in EX_NAMES) cbEx.Items.Add(n);
            cbEx.SelectedIndex = (_ex == "binance") ? 1 : 0;
            d.Controls.Add(cbEx);

            Label tip = new Label();
            tip.AutoSize = false;
            tip.ForeColor = Color.FromArgb(190, 60, 60);
            tip.SetBounds(16, 44, 528, 26);
            d.Controls.Add(tip);

            d.Controls.Add(MkLabel("API Key", 16, 84));
            TextBox t1 = MkBox("", 118, 80, 424);
            t1.UseSystemPasswordChar = false;          // 它不算秘密，明文才好核对
            d.Controls.Add(t1);

            d.Controls.Add(MkLabel("Secret Key", 16, 124));
            TextBox t2 = MkBox("", 118, 120, 424);
            d.Controls.Add(t2);

            Label lbPass = MkLabel("Passphrase", 16, 164);
            d.Controls.Add(lbPass);
            TextBox t3 = MkBox("", 118, 160, 424);
            d.Controls.Add(t3);

            CheckBox cbShow = new CheckBox();
            cbShow.Text = "显示明文（核对有没有粘错）";
            cbShow.SetBounds(118, 194, 300, 24);
            cbShow.CheckedChanged += delegate
            {
                t2.UseSystemPasswordChar = !cbShow.Checked;
                t3.UseSystemPasswordChar = !cbShow.Checked;
            };
            d.Controls.Add(cbShow);

            CheckBox cb = new CheckBox();
            cb.Text = "模拟盘 / 测试网 (demo)";
            cb.SetBounds(118, 222, 260, 24);
            d.Controls.Add(cb);

            Label lbNote = new Label();
            lbNote.AutoSize = false;
            lbNote.ForeColor = Color.FromArgb(96, 100, 106);
            lbNote.SetBounds(16, 254, 528, 90);
            d.Controls.Add(lbNote);

            bool loading = false;
            Action refresh = delegate
            {
                bool bn = (cbEx.SelectedIndex == 1);
                ApiKey src = bn ? _kb : _k;
                loading = true;
                t1.Text = src.Key;
                t2.Text = src.Secret;
                t3.Text = src.Pass;
                t3.Enabled = !bn;
                lbPass.Enabled = !bn;
                cb.Checked = src.Demo;
                loading = false;
                if (bn)
                {
                    tip.Text = "币安：请创建【只读】权限的 API Key（要用平仓才勾「允许合约交易」）。";
                    lbNote.Text = "币安没有 Passphrase，只需要 API Key 和 Secret Key 两项；注意区分"
                        + "「现货」和「合约」——本程序走的是 U 本位合约接口（fapi），"
                        + "Key 需要在币安「API 管理」里允许「合约」，并建议绑定 IP 白名单。";
                }
                else
                {
                    tip.Text = "OKX：请在后台创建【只读】权限的 API Key，切勿勾选交易和提现。";
                    lbNote.Text = "OKX 建 Key 时只显示 API Key 和 Secret Key，第三项 Passphrase 是你在创建时"
                        + "自己设的那串口令，之后不会再显示 —— 只拿到两项是正常的。忘了的话，去 OKX 删掉这个 Key"
                        + "重新建一个，创建时把 Passphrase 抄下来。";
                }
            };
            cbEx.SelectedIndexChanged += delegate { if (!loading) refresh(); };
            refresh();

            Button ok = new Button();
            ok.Text = "保存";
            ok.SetBounds(352, 408, 92, 32);
            ok.DialogResult = DialogResult.OK;
            d.Controls.Add(ok);

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.SetBounds(452, 408, 92, 32);
            cancel.DialogResult = DialogResult.Cancel;
            d.Controls.Add(cancel);

            d.AcceptButton = ok;
            d.CancelButton = cancel;

            bool wasDim = _autoDim;
            _autoDim = false;
            ApplyOpacity(1.0);
            try
            {
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    bool bn = (cbEx.SelectedIndex == 1);
                    ApiKey dst = bn ? _kb : _k;
                    dst.Key = t1.Text.Trim();
                    dst.Secret = t2.Text.Trim();
                    if (!bn) dst.Pass = t3.Text.Trim();
                    dst.Demo = cb.Checked;
                    _ex = bn ? "binance" : "okx";
                    SaveCfg();
                    _tried = false;
                    Relayout();
                    Invalidate();
                    FetchOnce();
                }
            }
            finally
            {
                _autoDim = wasDim;
                ApplyOpacity(_opacity);
                d.Dispose();
            }
        }


        private static Label MkLabel(string t, int x, int y)
        {
            Label l = new Label();
            l.Text = t;
            l.Anchor = AnchorStyles.Left | AnchorStyles.Top;
            l.SetBounds(x, y + 3, 98, 22);
            return l;
        }

        private static TextBox MkBox(string v, int x, int y, int w)
        {
            TextBox b = new TextBox();
            b.Text = v;
            b.UseSystemPasswordChar = true;
            b.Font = new Font("Consolas", 10f);
            b.SetBounds(x, y, w, 26);
            return b;
        }

        private static string Enc(string s)
        {
            if (s == null || s.Length == 0) return "";
            try
            {
                byte[] b = ProtectedData.Protect(Encoding.UTF8.GetBytes(s), null, DataProtectionScope.CurrentUser);
                return "dpapi:" + Convert.ToBase64String(b);
            }
            catch { return s; }
        }

        private static string Dec(string s)
        {
            if (s == null) return "";
            if (!s.StartsWith("dpapi:")) return s;
            try
            {
                byte[] b = ProtectedData.Unprotect(Convert.FromBase64String(s.Substring(6)), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(b);
            }
            catch { return ""; }
        }

        private void LoadCfg()
        {
            int uiver = 0;
            try
            {
                if (!File.Exists(_cfgPath)) return;
                foreach (string line in File.ReadAllLines(_cfgPath))
                {
                    string ln = line.Trim();
                    if (ln.Length == 0 || ln.StartsWith("#")) continue;
                    int i = ln.IndexOf('=');
                    if (i <= 0) continue;
                    string k = ln.Substring(0, i).Trim().ToLower();
                    string v = ln.Substring(i + 1).Trim();
                    if (k == "uiver") { int.TryParse(v, out uiver); }
                    else if (k == "x") { int t; if (int.TryParse(v, out t)) _x = t; }
                    else if (k == "y") { int t; if (int.TryParse(v, out t)) _y = t; }
                    else if (k == "opacity") { double t; if (double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out t)) _opacity = t; }
                    else if (k == "interval") { int t; if (int.TryParse(v, out t)) _interval = Math.Max(800, t); }
                    else if (k == "compact") { _compact = (v == "1"); }
                    else if (k == "autodim") { _autoDim = (v == "1"); }
                    else if (k == "mask") { _mask = (v == "1"); }
                    else if (k == "glass") { _glass = (v == "1"); }

                    else if (k == "bar" && v.Length > 0) { _bar = v; }
                    else if (k == "proxy") { _proxy = v; }
                    else if (k == "outline") { _outline = (v == "1"); }
                    else if (k == "light") { _light = (v == "1"); }
                    else if (k == "autotext") { _autoText = (v == "1"); }
                    else if (k == "invert") { _invert = (v == "1"); }
                    else if (k == "watch") { _watch = (v == "1"); }
                    else if (k == "watchinst" && v.Length > 2 && _watchSyms.Count == 0) { _watchSyms.Add(v.ToUpper()); }
                    else if (k == "watchprice") { _watchPrice = (v == "1"); }
                    else if (k == "watchkn") { int t; if (int.TryParse(v, out t)) _watchKn = Math.Max(2, Math.Min(20, t)); }
                    else if (k == "watchkbar") { _watchKBar = v.Trim(); }
                    else if (k == "watchsyms" && v.Length > 2)
                    {
                        _watchSyms.Clear();
                        foreach (string s in v.Split(new char[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                        {
                            string id = s.Trim().ToUpper();
                            if (id.Length > 3 && !_watchSyms.Contains(id) && _watchSyms.Count < 6) _watchSyms.Add(id);
                        }
                    }
                    else if (k == "apikey") { _k.Key = Dec(v); }
                    else if (k == "secret") { _k.Secret = Dec(v); }
                    else if (k == "passphrase") { _k.Pass = Dec(v); }
                    else if (k == "demo") { _k.Demo = (v == "1"); }
                    else if (k == "exchange") { _ex = (v == "binance") ? "binance" : "okx"; }
                    else if (k == "bnkey") { _kb.Key = Dec(v); }
                    else if (k == "bnsecret") { _kb.Secret = Dec(v); }
                    else if (k == "bndemo") { _kb.Demo = (v == "1"); }
                }
                // 旧配置(无 uiver)沿用 0.55 浓度且无描边, 在桌面上几乎看不清, 一次性升级
                if (uiver < 2)
                {
                    if (_opacity < 0.9) _opacity = 0.95;
                    _outline = true;
                }
            }
            catch { }
        }

        private void SaveCfg()
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("# 持仓盈亏悬浮窗配置");
                sb.AppendLine("# key/secret/passphrase 已用 Windows DPAPI 加密,只能在本机本账户解密");
                sb.AppendLine("uiver=2");
                sb.AppendLine("apikey=" + Enc(_k.Key));
                sb.AppendLine("secret=" + Enc(_k.Secret));
                sb.AppendLine("passphrase=" + Enc(_k.Pass));
                sb.AppendLine("demo=" + (_k.Demo ? "1" : "0"));
                sb.AppendLine("# 交易所: okx | binance（币安走 U 本位合约 fapi）");
                sb.AppendLine("exchange=" + _ex);
                sb.AppendLine("bnkey=" + Enc(_kb.Key));
                sb.AppendLine("bnsecret=" + Enc(_kb.Secret));
                sb.AppendLine("bndemo=" + (_kb.Demo ? "1" : "0"));
                sb.AppendLine("x=" + _x);
                sb.AppendLine("y=" + _y);
                sb.AppendLine("opacity=" + _opacity.ToString("0.00", CultureInfo.InvariantCulture));
                sb.AppendLine("interval=" + _interval);
                sb.AppendLine("compact=" + (_compact ? "1" : "0"));
                sb.AppendLine("autodim=" + (_autoDim ? "1" : "0"));
                sb.AppendLine("mask=" + (_mask ? "1" : "0"));
                sb.AppendLine("# glass=0 背景全透明只留数字; glass=1 带半透明底板");
                sb.AppendLine("glass=" + (_glass ? "1" : "0"));

                sb.AppendLine("bar=" + _bar);
                sb.AppendLine("# proxy 留空=跟随系统代理; @direct=强制直连; 或填 http://127.0.0.1:7890");
                sb.AppendLine("proxy=" + _proxy);
                sb.AppendLine("# outline=1 数字加深色描边(浅色壁纸更清楚); 0 = 原始无描边");
                sb.AppendLine("outline=" + (_outline ? "1" : "0"));
                sb.AppendLine("# light=1 浅色卡片（深色字、不透明底，像系统时钟那样清楚）");
                sb.AppendLine("light=" + (_light ? "1" : "0"));
                sb.AppendLine("# autotext=1 透明模式下按背景明暗自动切换深/浅字");
                sb.AppendLine("autotext=" + (_autoText ? "1" : "0"));
                sb.AppendLine("# invert=1 颜色反转：涨绿跌红");
                sb.AppendLine("invert=" + (_invert ? "1" : "0"));
                sb.AppendLine("# watch=1 面板里插入一行实时看盘; watchinst=看盘币对");
                sb.AppendLine("watch=" + (_watch ? "1" : "0"));
                sb.AppendLine("watchsyms=" + string.Join(",", _watchSyms.ToArray()));
                sb.AppendLine("watchprice=" + (_watchPrice ? "1" : "0"));
                sb.AppendLine("# 小K线：根数 watchkn；周期 watchkbar 留空=跟随看盘周期");
                sb.AppendLine("watchkn=" + _watchKn);
                sb.AppendLine("watchkbar=" + _watchKBar);
                File.WriteAllText(_cfgPath, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }

        private void StartNet()
        {
            if (_netTimer != null) _netTimer.Dispose();
            _netTimer = new System.Threading.Timer(NetTick, null, 200, _interval);
        }

        private void NetTick(object st) { FetchOnce(); }

        public void FetchOnce()
        {
            if (_busy) return;
            _busy = true;
            try
            {
                if (!_ak.Ready)
                {
                    _tried = true;
                    _online = false;
                    _lastErr = "未配置 API Key";
                    if (this.IsHandleCreated && !this.IsDisposed)
                        this.BeginInvoke((MethodInvoker)delegate { Relayout(); Invalidate(); });
                    return;
                }

                List<Pos> list = new List<Pos>();
                double eq = 0;
                double upl = 0;
                string err = "";

                if (_ex == "binance")
                {
                    FetchBinance(list, ref eq, ref upl, ref err);
                }
                else
                {
                    try
                    {
                        string bj = ApiGet("/api/v5/account/balance", _proxy, _k);
                        eq = GetNum(bj, "totalEq");
                    }
                    catch (Exception ex) { err = ex.Message; }

                    try
                    {
                        string pj = ApiGet("/api/v5/account/positions", _proxy, _k);
                        list = ParsePositions(pj);
                        foreach (Pos p in list) upl += p.Upl;
                    }
                    catch (Exception ex) { err = ex.Message; }
                }

                if (_watch) FetchWatch();

                _tried = true;
                _online = (eq > 0 || list.Count > 0 || err.Length == 0);
                _lastErr = err;

                if (this.IsHandleCreated && !this.IsDisposed)
                {
                    this.BeginInvoke((MethodInvoker)delegate
                    {
                        _pos = list;
                        _snap = list;
                        _totalEq = eq;
                        _upl = upl;
                        Relayout();
                        Invalidate();
                    });
                }
            }
            catch (Exception ex)
            {
                _lastErr = ex.Message;
                _online = false;
            }
            finally
            {
                _busy = false;
            }
        }

        public static List<Pos> ParsePositions(string json)
        {
            List<Pos> res = new List<Pos>();
            if (json == null) return res;
            if (!Regex.IsMatch(json, "\"code\"\\s*:\\s*\"0\"")) return res;
            foreach (string obj in SplitObjects(json))
            {
                Pos p = new Pos();
                p.InstId = GetStr(obj, "instId");
                p.Side = GetStr(obj, "posSide");
                p.Size = GetNum(obj, "pos");
                p.AvgPx = GetNum(obj, "avgPx");
                p.MarkPx = GetNum(obj, "markPx");
                p.Upl = GetNum(obj, "upl");
                p.Ratio = GetNum(obj, "uplRatio") * 100.0;
                p.Lever = GetNum(obj, "lever");
                p.LiqPx = GetNum(obj, "liqPx");
                string mg = GetStr(obj, "mgnMode");
                if (mg.Length > 0) p.MgnMode = mg;
                p.Name = Short(p.InstId);
                if (Math.Abs(p.Size) < 0.0000001) continue;
                res.Add(p);
            }
            res.Sort(delegate (Pos a, Pos b) { return Math.Abs(b.Upl).CompareTo(Math.Abs(a.Upl)); });
            return res;
        }

        public static List<Candle> FetchCandles(string instId, string bar, int limit, string proxy)
        {
            string url = "https://www.okx.com/api/v5/market/candles?instId=" + instId + "&bar=" + bar + "&limit=" + limit;
            return ParseCandles(HttpGet(url, proxy));
        }

        public static List<Candle> ParseCandles(string json)
        {
            List<Candle> res = new List<Candle>();
            if (json == null) return res;
            MatchCollection ms = Regex.Matches(json,
                "\\[\"(\\d+)\",\"([0-9.eE+-]+)\",\"([0-9.eE+-]+)\",\"([0-9.eE+-]+)\",\"([0-9.eE+-]+)\"");
            foreach (Match m in ms)
            {
                Candle c = new Candle();
                c.O = Cv(m.Groups[2].Value);
                c.H = Cv(m.Groups[3].Value);
                c.L = Cv(m.Groups[4].Value);
                c.C = Cv(m.Groups[5].Value);
                if (c.C > 0 && c.H >= c.L) res.Add(c);
            }
            res.Reverse();
            return res;
        }

        private static double Cv(string s)
        {
            double v;
            double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v);
            return v;
        }

        public static string HttpGet(string url, string proxy)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = 6000;
            req.ReadWriteTimeout = 6000;
            req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
            req.Accept = "application/json";
            if (proxy != null && proxy.Length > 0)
            {
                if (proxy == "@system") req.Proxy = WebRequest.DefaultWebProxy;
                else if (proxy == "@direct") req.Proxy = null;
                else req.Proxy = new WebProxy(proxy);
            }
            try { req.Proxy.Credentials = CredentialCache.DefaultCredentials; } catch { }
            using (WebResponse rp = req.GetResponse())
            using (Stream s = rp.GetResponseStream())
            using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                return sr.ReadToEnd();
        }

        private void DrawKline(Graphics g, List<Candle> cs, RectangleF r)
        {
            if (cs == null || cs.Count < 2 || r.Width < 8) return;
            double hi = double.MinValue;
            double lo = double.MaxValue;
            foreach (Candle c in cs)
            {
                if (c.H > hi) hi = c.H;
                if (c.L < lo) lo = c.L;
            }
            if (hi <= lo) return;
            double span = hi - lo;
            float step = r.Width / cs.Count;
            float bw = Math.Max(1.2f, step * 0.62f);
            for (int i = 0; i < cs.Count; i++)
            {
                Candle c = cs[i];
                float xc = r.X + i * step + step / 2f;
                float yh = r.Bottom - (float)((c.H - lo) / span * (r.Height - 2)) - 1;
                float yl = r.Bottom - (float)((c.L - lo) / span * (r.Height - 2)) - 1;
                float yo = r.Bottom - (float)((c.O - lo) / span * (r.Height - 2)) - 1;
                float yc = r.Bottom - (float)((c.C - lo) / span * (r.Height - 2)) - 1;
                bool up = c.C >= c.O;
                Color col = up ? CU : CD;
                using (Pen p = new Pen(col, 1f))
                    g.DrawLine(p, xc, yh, xc, yl);
                float top = Math.Min(yo, yc);
                float bh = Math.Max(1f, Math.Abs(yc - yo));
                using (SolidBrush b = new SolidBrush(col))
                    g.FillRectangle(b, xc - bw / 2f, top, bw, bh);
            }
        }

        public static string ApiGet(string pathWithQuery, string proxy, ApiKey k)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            string ts = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
            string sign = Sign(k.Secret, ts + "GET" + pathWithQuery);

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://www.okx.com" + pathWithQuery);
            req.Method = "GET";
            req.Timeout = 8000;
            req.ReadWriteTimeout = 8000;
            req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
            req.Accept = "application/json";
            req.Headers.Add("OK-ACCESS-KEY", k.Key);
            req.Headers.Add("OK-ACCESS-SIGN", sign);
            req.Headers.Add("OK-ACCESS-TIMESTAMP", ts);
            req.Headers.Add("OK-ACCESS-PASSPHRASE", k.Pass);
            if (k.Demo) req.Headers.Add("x-simulated-trading", "1");

            if (proxy != null && proxy.Length > 0)
            {
                if (proxy == "@system") req.Proxy = WebRequest.DefaultWebProxy;
                else if (proxy == "@direct") req.Proxy = null;
                else req.Proxy = new WebProxy(proxy);
            }
            try { req.Proxy.Credentials = CredentialCache.DefaultCredentials; } catch { }

            using (WebResponse rp = req.GetResponse())
            using (Stream s = rp.GetResponseStream())
            using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                return sr.ReadToEnd();
        }

        /// <summary>签名 POST（平仓等写操作）；返回 OKX 原始 JSON，业务错误交给调用方判断</summary>
        public static string ApiPost(string path, string body, string proxy, ApiKey k)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            string ts = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
            string sign = Sign(k.Secret, ts + "POST" + path + body);

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create("https://www.okx.com" + path);
            req.Method = "POST";
            req.Timeout = 12000;
            req.ReadWriteTimeout = 12000;
            req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
            req.ContentType = "application/json";
            req.Accept = "application/json";
            req.Headers.Add("OK-ACCESS-KEY", k.Key);
            req.Headers.Add("OK-ACCESS-SIGN", sign);
            req.Headers.Add("OK-ACCESS-TIMESTAMP", ts);
            req.Headers.Add("OK-ACCESS-PASSPHRASE", k.Pass);
            if (k.Demo) req.Headers.Add("x-simulated-trading", "1");

            if (proxy != null && proxy.Length > 0)
            {
                if (proxy == "@system") req.Proxy = WebRequest.DefaultWebProxy;
                else if (proxy == "@direct") req.Proxy = null;
                else req.Proxy = new WebProxy(proxy);
            }
            try { req.Proxy.Credentials = CredentialCache.DefaultCredentials; } catch { }

            byte[] data = Encoding.UTF8.GetBytes(body == null ? "{}" : body);
            req.ContentLength = data.Length;
            using (Stream ws = req.GetRequestStream()) ws.Write(data, 0, data.Length);

            try
            {
                using (WebResponse rp = req.GetResponse())
                using (Stream s = rp.GetResponseStream())
                using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                    return sr.ReadToEnd();
            }
            catch (WebException wex)
            {
                if (wex.Response != null)
                {
                    using (Stream es = wex.Response.GetResponseStream())
                    using (StreamReader er = new StreamReader(es, Encoding.UTF8))
                        return er.ReadToEnd();
                }
                throw;
            }
        }


        // ================= 币安 U 本位合约（fapi）=================

        public const string BN_BASE = "https://fapi.binance.com";

        /// <summary>BTC-USDT-SWAP ↔ BTCUSDT</summary>
        public static string ToBinSym(string inst)
        {
            if (inst == null) return "";
            return inst.Replace("-SWAP", "").Replace("-", "");
        }

        public static string ToOkxInst(string sym)
        {
            if (sym == null) return "";
            string s = sym.ToUpper();
            if (s.EndsWith("USDT")) return s.Substring(0, s.Length - 4) + "-USDT-SWAP";
            if (s.EndsWith("USDC")) return s.Substring(0, s.Length - 4) + "-USDC-SWAP";
            return s;
        }

        /// <summary>OKX 的 1H/4H/1D → 币安的 1h/4h/1d</summary>
        public static string BarToBin(string bar)
        {
            if (bar == null || bar.Length == 0) return "5m";
            if (bar.EndsWith("H")) return bar.Substring(0, bar.Length - 1) + "h";
            if (bar.EndsWith("D")) return bar.Substring(0, bar.Length - 1) + "d";
            if (bar.EndsWith("W")) return bar.Substring(0, bar.Length - 1) + "w";
            return bar;
        }

        public static string KlineUrl(string ex, string inst, string bar, int n)
        {
            if (ex == "binance")
                return BN_BASE + "/fapi/v1/klines?symbol=" + ToBinSym(inst) + "&interval=" + BarToBin(bar) + "&limit=" + n;
            return "https://www.okx.com/api/v5/market/candles?instId=" + inst + "&bar=" + bar + "&limit=" + n;
        }

        public static string TickerUrl(string ex, string inst)
        {
            if (ex == "binance")
                return BN_BASE + "/fapi/v1/ticker/24hr?symbol=" + ToBinSym(inst);
            return "https://www.okx.com/api/v5/market/ticker?instId=" + inst;
        }

        /// <summary>从 ticker 返回里取 24h 涨跌幅（%）</summary>
        public static double Chg24Of(string ex, string body)
        {
            if (ex == "binance")
            {
                double pc = GetNum(body, "priceChangePercent");
                return pc;
            }
            double lp = GetNum(body, "last");
            double op = GetNum(body, "open24h");
            return op > 0 ? (lp - op) / op * 100.0 : 0;
        }

        /// <summary>顶层对象数组的拆分（币安没有 "data" 外层）</summary>
        public static List<string> SplitTopObjects(string json)
        {
            List<string> res = new List<string>();
            if (json == null) return res;
            int i = json.IndexOf('[');
            int from = i < 0 ? 0 : i;
            int depth = 0, start = -1;
            for (int p = from; p < json.Length; p++)
            {
                char c = json[p];
                if (c == '{') { if (depth == 0) start = p; depth++; }
                else if (c == '}')
                {
                    depth--;
                    if (depth == 0 && start >= 0) { res.Add(json.Substring(start, p - start + 1)); start = -1; }
                }
            }
            return res;
        }

        /// <summary>币安签名请求：query 不用带 timestamp，这里统一补+签名</summary>
        public static string BinanceRequest(string method, string path, string query, string proxy, ApiKey k, bool demo)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            string baseUrl = demo ? "https://testnet.binancefuture.com" : BN_BASE;
            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            string q = (query == null ? "" : query.Trim().Trim('&'));
            if (q.Length > 0) q += "&";
            q += "timestamp=" + ts + "&recvWindow=5000";
            string sig = Sign(k.Secret, q);
            string url = baseUrl + path + "?" + q + "&signature=" + sig;

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = method;
            req.Timeout = 12000;
            req.ReadWriteTimeout = 12000;
            req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
            req.Accept = "application/json";
            req.Headers.Add("X-MBX-APIKEY", k.Key);
            if (proxy != null && proxy.Length > 0)
            {
                if (proxy == "@system") req.Proxy = WebRequest.DefaultWebProxy;
                else if (proxy == "@direct") req.Proxy = null;
                else req.Proxy = new WebProxy(proxy);
            }
            try { req.Proxy.Credentials = CredentialCache.DefaultCredentials; } catch { }
            if (method == "POST")
            {
                req.ContentType = "application/x-www-form-urlencoded";
                req.ContentLength = 0;
            }
            try
            {
                using (WebResponse rp = req.GetResponse())
                using (Stream s = rp.GetResponseStream())
                using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
                    return sr.ReadToEnd();
            }
            catch (WebException wex)
            {
                if (wex.Response != null)
                {
                    using (Stream es = wex.Response.GetResponseStream())
                    using (StreamReader er = new StreamReader(es, Encoding.UTF8))
                        return er.ReadToEnd();
                }
                throw;
            }
        }

        /// <summary>币安持仓：positionRisk → Pos（InstId 统一成 OKX 风格，复用界面与看盘逻辑）</summary>
        public static List<Pos> ParseBinancePositions(string json)
        {
            List<Pos> res = new List<Pos>();
            foreach (string o in SplitTopObjects(json))
            {
                double amt = GetNum(o, "positionAmt");
                if (Math.Abs(amt) < 1e-12) continue;
                Pos p = new Pos();
                p.InstId = ToOkxInst(GetStr(o, "symbol"));
                string ps = GetStr(o, "positionSide");
                p.Side = ps == "LONG" ? "long" : (ps == "SHORT" ? "short" : (amt > 0 ? "long" : "short"));
                p.Size = Math.Abs(amt);
                p.AvgPx = GetNum(o, "entryPrice");
                p.MarkPx = GetNum(o, "markPrice");
                p.Upl = GetNum(o, "unRealizedProfit");
                p.Lever = GetNum(o, "leverage");
                p.LiqPx = GetNum(o, "liquidationPrice");
                p.MgnMode = "cross";
                double notional = p.Size * p.AvgPx;
                p.Ratio = notional > 0 ? p.Upl * Math.Max(1.0, p.Lever) / notional * 100.0 : 0;
                res.Add(p);
            }
            return res;
        }

        /// <summary>拉币安的权益/持仓（U 本位合约）</summary>
        private void FetchBinance(List<Pos> list, ref double eq, ref double upl, ref string err)
        {
            try
            {
                string bj = BinanceRequest("GET", "/fapi/v2/account", "", _proxy, _kb, _kb.Demo);
                eq = GetNum(bj, "totalMarginBalance");
                if (eq <= 0) eq = GetNum(bj, "totalWalletBalance") + GetNum(bj, "totalUnrealizedProfit");
                if (bj.IndexOf("code") >= 0 && bj.IndexOf("totalWalletBalance") < 0)
                    err = "币安: " + GetStr(bj, "msg");
            }
            catch (Exception ex) { err = "币安余额: " + ex.Message; }

            try
            {
                string pj = BinanceRequest("GET", "/fapi/v2/positionRisk", "", _proxy, _kb, _kb.Demo);
                List<Pos> ps = ParseBinancePositions(pj);
                list.AddRange(ps);
                foreach (Pos p in ps) upl += p.Upl;
                if (pj.IndexOf("code") >= 0 && pj.IndexOf("symbol") < 0)
                    err = "币安持仓: " + GetStr(pj, "msg");
            }
            catch (Exception ex) { err = "币安持仓: " + ex.Message; }
        }

        /// <summary>平掉一笔持仓：二次确认 → 本机签名调用 close-position</summary>
        private void ClosePosition(Pos p)
        {
            if (p == null) return;
            if (!_ak.Ready)
            {
                MessageBox.Show("还没配置 API Key。", "平仓", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string side = (p.Side == "short") ? "空" : (p.Side == "long" ? "多" : "");
            string nl = Environment.NewLine;
            string q = "确认平掉这笔持仓？" + nl + nl
                + p.InstId + "  " + side + nl
                + "数量 " + p.Size.ToString("0.####", CultureInfo.InvariantCulture) + nl
                + "开仓均价 " + p.AvgPx.ToString("#,0.####", CultureInfo.InvariantCulture) + nl
                + "当前浮盈 " + Money(p.Upl, true) + nl + nl
                + "点「是」会立刻以市价平仓，不可撤回。";
            if (MessageBox.Show(q, "一键平仓", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                return;

            if (_ex == "binance")
            {
                CloseBinance(p);
                return;
            }

            string dq = ((char)34).ToString();
            string body = "{" + dq + "instId" + dq + ":" + dq + p.InstId + dq
                + "," + dq + "posSide" + dq + ":" + dq + p.Side + dq
                + "," + dq + "mgnMode" + dq + ":" + dq
                + (p.MgnMode == null || p.MgnMode.Length == 0 ? "cross" : p.MgnMode) + dq + "}";

            string resp;
            try
            {
                resp = ApiPost("/api/v5/trade/close-position", body, _proxy, _k);
            }
            catch (Exception ex)
            {
                MessageBox.Show("平仓请求失败：" + nl + ex.Message, "一键平仓", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string code = GetStr(resp, "code");
            if (code == "0")
            {
                MessageBox.Show("已下单平仓：" + p.InstId + " " + side, "一键平仓",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else if (code == "50110" || code == "50113" || code == "50101")
            {
                MessageBox.Show("OKX 拒绝了这次平仓：" + code + " " + GetStr(resp, "msg") + nl + nl
                    + "常见原因：Key 没勾「交易」权限 / 本机 IP 不在白名单 / 系统时间偏差。", "一键平仓",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            else
            {
                MessageBox.Show("平仓被拒绝：" + code + " " + GetStr(resp, "msg"), "一键平仓",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            FetchOnce();
        }

        /// <summary>币安平仓：市价单 + reduceOnly（单向持仓）；对冲模式自动改 positionSide</summary>
        private void CloseBinance(Pos p)
        {
            string nl = Environment.NewLine;
            string sym = ToBinSym(p.InstId);
            string side = (p.Side == "short") ? "BUY" : "SELL";
            string qty = p.Size.ToString("0.########", CultureInfo.InvariantCulture);
            string baseQ = "symbol=" + sym + "&side=" + side + "&type=MARKET&quantity=" + qty + "&newOrderRespType=RESULT";

            string resp = "";
            try
            {
                resp = BinanceRequest("POST", "/fapi/v1/order", baseQ + "&reduceOnly=true", _proxy, _kb, _kb.Demo);
                if (resp.IndexOf("reduceOnly") >= 0 && resp.IndexOf("orderId") < 0)
                {
                    // 对冲模式不支持 reduceOnly，改用 positionSide
                    string ps = (p.Side == "short") ? "SHORT" : "LONG";
                    resp = BinanceRequest("POST", "/fapi/v1/order", baseQ + "&positionSide=" + ps, _proxy, _kb, _kb.Demo);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("平仓请求失败：" + nl + ex.Message, "一键平仓", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (resp.IndexOf("orderId") >= 0)
            {
                MessageBox.Show("已下单平仓：" + p.InstId + " " + qty, "一键平仓",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else
            {
                MessageBox.Show("平仓被拒绝：" + GetStr(resp, "msg") + nl + nl
                    + "常见原因：Key 没开「合约交易」权限 / IP 不在白名单 / 系统时间偏差。", "一键平仓",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            FetchOnce();
        }

        private void ToggleChart()
        {
            try
            {
                if (_chart == null || _chart.IsDisposed)
                    _chart = new KForm(_dir, _proxy, _invert, _ex);
                if (_chart.Visible) { _chart.Hide(); }
                else { _chart.Show(); _chart.TopMost = true; _chart.Activate(); }
            }
            catch { }
        }

        private void RedrawSafe()
        {
            if (this.IsHandleCreated && !this.IsDisposed)
                this.BeginInvoke((MethodInvoker)delegate { Relayout(); Invalidate(); });
        }

        /// <summary>兼容 /api/kline 的 [ts,o,h,l,c,...] 行与 OKX 原生 candles，统一成升序 Candle。</summary>
        public static List<Candle> ParseKlineRows(string json)
        {
            List<Candle> res = new List<Candle>();
            if (json == null) return res;
            MatchCollection ms = Regex.Matches(json,
                "\\[\\s*\"?(\\d{10,})\"?\\s*,\\s*\"?([-0-9.eE]+)\"?\\s*,\\s*\"?([-0-9.eE]+)\"?\\s*,\\s*\"?([-0-9.eE]+)\"?\\s*,\\s*\"?([-0-9.eE]+)\"?");
            List<long> ts = new List<long>();
            foreach (Match m in ms)
            {
                long t;
                if (!long.TryParse(m.Groups[1].Value, out t)) continue;
                Candle c = new Candle();
                c.O = Cv(m.Groups[2].Value);
                c.H = Cv(m.Groups[3].Value);
                c.L = Cv(m.Groups[4].Value);
                c.C = Cv(m.Groups[5].Value);
                if (c.C <= 0 || c.H < c.L) continue;
                res.Add(c);
                ts.Add(t);
            }
            // 按时间戳排序，保证升序（OKX 原始是最新在前）
            List<int> idx = new List<int>();
            for (int i = 0; i < ts.Count; i++) idx.Add(i);
            idx.Sort(delegate(int a, int b) { return ts[a].CompareTo(ts[b]); });
            List<Candle> sorted = new List<Candle>();
            foreach (int i in idx) sorted.Add(res[i]);
            return sorted;
        }

        /// <summary>看盘可选币对：几个常用 + 已经添加的（自定义的也不会被藏起来）。</summary>
        private List<string> WatchSymbols()
        {
            List<string> res = new List<string>();
            res.Add("BTC-USDT-SWAP");
            res.Add("ETH-USDT-SWAP");
            res.Add("SOL-USDT-SWAP");
            res.Add("DOGE-USDT-SWAP");
            foreach (string s in _watchSyms) if (!res.Contains(s)) res.Add(s);
            return res;
        }

        private void WatchDialog()
        {
            Form d = new Form();
            d.Text = "看盘币对";
            d.FormBorderStyle = FormBorderStyle.FixedDialog;
            d.StartPosition = FormStartPosition.CenterScreen;
            d.MaximizeBox = false;
            d.MinimizeBox = false;
            d.ClientSize = new Size(400, 130);
            d.TopMost = true;
            d.Font = new Font("Microsoft YaHei", 10f);

            Label l = new Label();
            l.Text = "多个币对用逗号分隔（最多 6 个），例如：\r\nZEC-USDT-SWAP, ETH-USDT-SWAP, BTC-USDT-SWAP";
            l.AutoSize = false;
            l.SetBounds(16, 10, 388, 40);
            d.Controls.Add(l);

            TextBox tb = new TextBox();
            tb.Text = string.Join(", ", _watchSyms.ToArray());
            tb.Font = new Font("Consolas", 10f);
            tb.SetBounds(16, 44, 368, 26);
            d.Controls.Add(tb);

            Button ok = new Button();
            ok.Text = "确定";
            ok.SetBounds(220, 88, 78, 30);
            ok.DialogResult = DialogResult.OK;
            d.Controls.Add(ok);

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.SetBounds(306, 88, 78, 30);
            cancel.DialogResult = DialogResult.Cancel;
            d.Controls.Add(cancel);

            d.AcceptButton = ok;
            d.CancelButton = cancel;

            try
            {
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    List<string> list = new List<string>();
                    foreach (string s in tb.Text.Split(new char[] { ',', '，', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        string id = s.Trim().ToUpper();
                        if (id.Length > 3 && !list.Contains(id) && list.Count < 6) list.Add(id);
                    }
                    if (list.Count > 0)
                    {
                        _watchSyms = list;
                        _watch = true;
                        InvalidateWatch();
                        SaveCfg();
                        FetchWatch();
                        Relayout();
                        Invalidate();
                    }
                }
            }
            finally { d.Dispose(); }
        }

        /// <summary>每个币对各自并发取数：1 秒刷新时互不排队，每个币对最多 1.5 秒一次。</summary>
        private void FetchWatch()
        {
            if (_watchSyms.Count == 0) return;
            List<string> todo = new List<string>();
            DateTime now = DateTime.UtcNow;
            lock (_lk)
            {
                foreach (string inst in _watchSyms)
                {
                    if (_watchInflight.Contains(inst)) continue;
                    DateTime at;
                    if (_watchFetchedAt.TryGetValue(inst, out at) && (now - at).TotalSeconds < 1.5) continue;
                    _watchInflight.Add(inst);
                    todo.Add(inst);
                }
            }
            foreach (string inst in todo)
            {
                string sid = inst;
                System.Threading.ThreadPool.QueueUserWorkItem(delegate(object st) { FetchWatchOne(sid); });
            }
        }

        private void FetchWatchOne(string inst)
        {
            try
            {
                // 小 K 线：周期可单独指定（留空=跟随看盘周期），根数可调；走 OKX 公有行情，不需要签名
                string kbar = _watchKBar.Length > 0 ? _watchKBar : _bar;
                string body = HttpGet(KlineUrl(_ex, inst, kbar, _watchKn), _proxy);

                string code = GetStr(body, "code");
                if (code.Length > 0 && code != "0")
                {
                    _watchErr = inst + " " + code + " " + GetStr(body, "msg");
                }
                else
                {
                    List<Candle> cs = ParseKlineRows(body);
                    if (cs.Count > 1)
                    {
                        // 24 小时涨跌幅：用公有 ticker 的 open24h（不需要签名），拿不到就退回窗口涨跌
                        double chg = cs[0].O > 0 ? (cs[cs.Count - 1].C - cs[0].O) / cs[0].O * 100.0 : 0;
                        try
                        {
                            string tk = HttpGet(TickerUrl(_ex, inst), _proxy);
                            double c24 = Chg24Of(_ex, tk);
                            if (c24 != 0) chg = c24;
                        }
                        catch { }

                        lock (_lk)
                        {
                            _watchMap[inst] = cs;
                            _watchChgMap[inst] = chg;
                            _watchLastMap[inst] = cs[cs.Count - 1].C;
                        }
                        _watchErr = "";
                    }
                }
            }
            catch (Exception ex)
            {
                _watchErr = inst + " " + ex.Message;
            }
            finally
            {
                lock (_lk)
                {
                    _watchInflight.Remove(inst);
                    _watchFetchedAt[inst] = DateTime.UtcNow;
                }
            }
            RedrawSafe();
        }

        /// <summary>让所有币对立即重新取数（换币对 / 切周期时用）</summary>
        private void InvalidateWatch()
        {
            lock (_lk) { _watchFetchedAt.Clear(); }
        }

        /// <summary>按价位量级选合适的小数位，0.06817 这种也要看得见</summary>
        private static string PriceStr(double p)
        {
            if (p >= 1000) return p.ToString("#,0.##", CultureInfo.InvariantCulture);
            if (p >= 10) return p.ToString("#,0.###", CultureInfo.InvariantCulture);
            if (p >= 1) return p.ToString("0.####", CultureInfo.InvariantCulture);
            if (p > 0) return p.ToString("0.#####", CultureInfo.InvariantCulture);
            return "--";
        }

        /// <summary>所有看盘胶囊排成一行需要的宽度（含右侧留白）</summary>
        private float WatchChipsWidth(Graphics g)
        {
            List<string> syms;
            Dictionary<string, double> chgs;
            lock (_lk)
            {
                syms = new List<string>(_watchSyms);
                chgs = new Dictionary<string, double>(_watchChgMap);
            }
            float total = 0;
            foreach (string inst in syms)
            {
                if (!chgs.ContainsKey(inst)) continue;
                total += S(9) + g.MeasureString(Short(inst), _fName).Width;
                if (_watchPrice)
                {
                    double lp;
                    if (_watchLastMap.TryGetValue(inst, out lp) && lp > 0)
                        total += S(4) + g.MeasureString(PriceStr(lp), _fNum).Width;
                }
                total += S(5) + g.MeasureString(Pct(chgs[inst]), _fNum).Width + S(10);
            }
            return total;
        }

        private int WatchChipRows(Graphics g, float avail)
        {
            if (avail <= 0) return 1;
            List<string> syms;
            Dictionary<string, double> chgs;
            lock (_lk)
            {
                syms = new List<string>(_watchSyms);
                chgs = new Dictionary<string, double>(_watchChgMap);
            }
            int rows = 1;
            float cx = 0;
            foreach (string inst in syms)
            {
                if (!chgs.ContainsKey(inst)) continue;
                float need = S(9) + g.MeasureString(Short(inst), _fName).Width;
                if (_watchPrice)
                {
                    double lp;
                    if (_watchLastMap.TryGetValue(inst, out lp) && lp > 0)
                        need += S(4) + g.MeasureString(PriceStr(lp), _fNum).Width;
                }
                need += S(5) + g.MeasureString(Pct(chgs[inst]), _fNum).Width + S(10);
                if (cx > 0 && cx + need > avail) { rows++; cx = 0; }
                cx += need;
            }
            return rows;
        }

        private bool WatchHasData()
        {
            lock (_lk) { return _watchMap.Count > 0; }
        }


        /// <summary>解析 JSON 里形如 candles:[[o,h,l,c], ...] 的数据（已是时间升序）</summary>
        public static List<Candle> ParseFlatCandles(string obj)
        {
            if (obj == null) return null;
            int i = obj.IndexOf("\"candles\"");
            if (i < 0) return null;
            int s = obj.IndexOf('[', i);
            if (s < 0) return null;

            int depth = 0;
            int e = -1;
            for (int p = s; p < obj.Length; p++)
            {
                char ch = obj[p];
                if (ch == '[') depth++;
                else if (ch == ']')
                {
                    depth--;
                    if (depth == 0) { e = p; break; }
                }
            }
            if (e < 0) return null;

            List<Candle> res = new List<Candle>();
            MatchCollection ms = Regex.Matches(obj.Substring(s, e - s + 1),
                "\\[\\s*([-0-9.eE]+)\\s*,\\s*([-0-9.eE]+)\\s*,\\s*([-0-9.eE]+)\\s*,\\s*([-0-9.eE]+)\\s*\\]");
            foreach (Match m in ms)
            {
                Candle c = new Candle();
                c.O = Cv(m.Groups[1].Value);
                c.H = Cv(m.Groups[2].Value);
                c.L = Cv(m.Groups[3].Value);
                c.C = Cv(m.Groups[4].Value);
                if (c.C > 0 && c.H >= c.L) res.Add(c);
            }
            return res;
        }

        public static string Sign(string secret, string prehash)
        {
            using (HMACSHA256 h = new HMACSHA256(Encoding.UTF8.GetBytes(secret)))
            {
                return Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes(prehash)));
            }
        }

        private static List<string> SplitObjects(string json)
        {
            List<string> res = new List<string>();
            int i = json.IndexOf("\"data\"");
            if (i < 0) return res;
            int s = json.IndexOf('[', i);
            if (s < 0) return res;
            int depth = 0;
            int start = -1;
            for (int p = s; p < json.Length; p++)
            {
                char c = json[p];
                if (c == '{') { if (depth == 0) start = p; depth++; }
                else if (c == '}')
                {
                    depth--;
                    if (depth == 0 && start >= 0) { res.Add(json.Substring(start, p - start + 1)); start = -1; }
                }
            }
            return res;
        }

        private static string GetStr(string json, string key)
        {
            Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : "";
        }

        private static double GetNum(string json, string key)
        {
            Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"?([-0-9\\.eE]+)\"?");
            if (!m.Success) return 0;
            double v;
            double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v);
            return v;
        }

        private static string Short(string id)
        {
            string s = id.ToUpper();
            if (s.EndsWith("-SWAP")) return s.Replace("-USDT-SWAP", "").Replace("-USDC-SWAP", "");
            return s.Replace("-USDT", "").Replace("-USDC", "");
        }

        private string Money(double v, bool withSign)
        {
            if (_mask) return "••••";
            string s = Math.Abs(v).ToString("#,0.0", CultureInfo.InvariantCulture);
            if (withSign) return (v >= 0 ? "+" : "-") + s;
            return (v < 0 ? "-" : "") + s;
        }

        private static string Pct(double v)
        {
            string sign = v > 0.0001 ? "+" : "";
            return sign + v.ToString("0.0", CultureInfo.InvariantCulture) + "%";
        }

        private Color ColorOf(double p)
        {
            if (p > 0.0001) return CU;
            if (p < -0.0001) return CD;
            return CF;
        }

        // 所有像素尺寸统一走这两个换算, 100% DPI 时等于原值
        private float S(float v) { return v * _s; }
        private int Si(float v) { return (int)Math.Round(v * _s); }
        private int HeadH() { return Si(23); }
        private int RowH() { return Si(24); }
        private int WatchLabH() { return Si(24); }
        private int WatchChartH() { return Si(46); }
        private int WatchBlockH() { return WatchLabH(); }

        // 右侧三列的宽度(从右往左: 盈亏 / 涨跌幅 / 迷你K线)
        // 两列宽度按实际数字长度自动收，别为 "+0.3" 留一大块空白
        private float _colMoney = 76f;
        private float _colPct = 58f;
        private float _nameW = 42f;
        private float ColMoney { get { return _colMoney * _s; } }
        private float ColPct { get { return _colPct * _s; } }


        // 极简单行右侧: 有仓位显示浮动盈亏, 空仓直接写"空仓", 免得像取不到数
        private string CompactRight()
        {
            if (_pos.Count == 0 && _totalEq > 0) return "空仓";
            return Money(_upl, true);
        }

        private void Relayout()
        {
            if (!this.IsHandleCreated) return;
            using (Graphics g = this.CreateGraphics())
            {
                if (_compact)
                {
                    int h = Si(32);
                    int w = Si(240);
                    if (Configured && (_pos.Count > 0 || _totalEq > 0))
                    {
                        float padL = _glass ? S(13) : S(5);
                        float textX = padL + S(15);
                        string eqs = _mask ? "••••" : _totalEq.ToString("#,0.0", CultureInfo.InvariantCulture);
                        string pls = CompactRight();
                        float ew = g.MeasureString(eqs, _fTag).Width;
                        float pw = g.MeasureString(pls, _fTag).Width;
                        w = (int)Math.Ceiling(textX + ew + S(12) + pw + S(15));
                    }
                    w = Math.Max(Si(180), Math.Min(w, Si(640)));
                    if (this.Width != w || this.Height != h) this.Size = new Size(w, h);
                }
                else
                {
                    int cnt = Math.Min(_pos.Count, 6);
                    int rowH = RowH();
                    float gap = S(7);
                    float padL = _glass ? S(13) : S(5);

                    List<string> syms;
                    Dictionary<string, double> chgs;
                    Dictionary<string, double> lasts;
                    lock (_lk)
                    {
                        syms = new List<string>(_watchSyms);
                        chgs = new Dictionary<string, double>(_watchChgMap);
                        lasts = new Dictionary<string, double>(_watchLastMap);
                    }
                    int chipRows = 0;
                    if (_watch) foreach (string inst in syms) if (chgs.ContainsKey(inst)) chipRows++;

                    // 三列统一：名字 | 看盘价/持仓涨跌幅 | 看盘涨幅/持仓盈亏
                    float nameW = S(38);
                    foreach (Pos p in _pos)
                    {
                        float need = g.MeasureString(p.Name, _fName).Width + g.MeasureString("空", _fName).Width + S(3);
                        if (need > nameW) nameW = need;
                    }
                    float colA = g.MeasureString(Pct(_upl), _fNum).Width;
                    float colB = g.MeasureString(Money(_upl, true), _fNum).Width;
                    foreach (Pos p in _pos)
                    {
                        float a = g.MeasureString(Pct(p.Ratio), _fNum).Width;
                        float b = g.MeasureString(Money(p.Upl, true), _fNum).Width;
                        if (a > colA) colA = a;
                        if (b > colB) colB = b;
                    }
                    if (_watch)
                    {
                        foreach (string inst in syms)
                        {
                            if (!chgs.ContainsKey(inst)) continue;
                            float nmw = g.MeasureString(Short(inst), _fName).Width + S(4);
                            if (nmw > nameW) nameW = nmw;
                            double lp;
                            if (_watchPrice && lasts.TryGetValue(inst, out lp) && lp > 0)
                            {
                                float a = g.MeasureString(PriceStr(lp), _fNum).Width;
                                if (a > colA) colA = a;
                            }
                            float b = g.MeasureString(Pct(chgs[inst]), _fNum).Width;
                            if (b > colB) colB = b;
                        }
                    }
                    _colPct = Math.Max(40f, Math.Min(96f, colA / _s + 6f));
                    _colMoney = Math.Max(38f, Math.Min(110f, colB / _s + 6f));
                    _nameW = Math.Max(38f, nameW / _s);

                    // 看盘行要留一小段画 5 根 K 线
                    float chartW = chipRows > 0 ? Math.Max(S(30), Math.Min(S(64), S(18 + _watchKn * 4))) : 0;

                    int w = (int)Math.Ceiling(padL * 2 + nameW + chartW + gap + ColPct + gap + ColMoney);
                    if (w < Si(200)) w = Si(200);

                    int watchH = chipRows * WatchLabH();

                    int h;
                    if (cnt == 0) h = Si(7) + HeadH() + watchH + RowH() + Si(2);
                    else h = Si(7) + HeadH() + watchH + cnt * rowH + Si(9);
                    if (this.Width != w || this.Height != h) this.Size = new Size(w, h);
                }
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // 不透明底板上用 ClearType，字更实；透明模式只能用灰度抗锯齿
            g.TextRenderingHint = (_glass || _light)
                ? System.Drawing.Text.TextRenderingHint.ClearTypeGridFit
                : System.Drawing.Text.TextRenderingHint.AntiAlias;

            if (_light)
            {
                using (GraphicsPath p = Rounded(new Rectangle(0, 0, Width, Height), Si(9)))
                using (SolidBrush bg = new SolidBrush(Color.FromArgb(255, 245, 246, 248)))
                {
                    g.FillPath(bg, p);
                }
                using (GraphicsPath p2 = Rounded(new Rectangle(0, 0, Width - 1, Height - 1), Si(9)))
                using (Pen pen = new Pen(Color.FromArgb(210, 214, 220)))
                {
                    g.DrawPath(pen, p2);
                }
            }
            else if (_glass)
            {
                using (GraphicsPath p = Rounded(new Rectangle(0, 0, Width, Height), Si(9)))
                using (SolidBrush bg = new SolidBrush(Color.FromArgb(255, 16, 17, 19)))
                {
                    g.FillPath(bg, p);
                }
                using (GraphicsPath p2 = Rounded(new Rectangle(0, 0, Width - 1, Height - 1), Si(9)))
                using (Pen pen = new Pen(Color.FromArgb(64, 255, 255, 255)))
                {
                    g.DrawPath(pen, p2);
                }
            }

            if (_compact) PaintCompact(g);
            else PaintList(g);
        }

        private Color StatusColor()
        {
            if (!_tried) return Color.FromArgb(150, 150, 152, 156);
            if (!Configured) return Color.FromArgb(220, 205, 172, 62);
            if (_online) return Color.FromArgb(230, 62, 190, 120);
            return Color.FromArgb(230, 226, 72, 72);
        }

        private static readonly Color CSH = Color.FromArgb(246, 9, 10, 12);

        /// <summary>
        /// 带描边的文字：沿着字形轮廓描一圈深灰再填色。
        /// 比「八向偏移绘制」干净——小字号不会把字心糊死；也不用纯黑，
        /// 因为透明底板下纯黑会被 TransparencyKey 当成透明区域。
        /// </summary>
        private void Txt(Graphics g, string s, Font f, Brush b, PointF p)
        {

            if (!_outline)
            {
                // 不描边：就是纯字体颜色，不加投影
                g.DrawString(s, f, b, p);
                return;
            }
            using (GraphicsPath gp = new GraphicsPath())
            {
                float em = f.SizeInPoints * g.DpiY / 72f;
                gp.AddString(s, f.FontFamily, (int)f.Style, em, p, StringFormat.GenericDefault);
                float pw = f.SizeInPoints < 8.6f ? 1.15f : 1.7f;
                using (Pen pen = new Pen(CSH, Math.Max(pw, pw * _s)))
                {
                    pen.LineJoin = LineJoin.Round;
                    g.DrawPath(pen, gp);
                }
                g.FillPath(b, gp);
            }
        }

        private void TxtR(Graphics g, string s, Font f, Brush b, RectangleF r, StringFormat sf)
        {

            if (!_outline)
            {
                g.DrawString(s, f, b, r, sf);
                return;
            }
            using (GraphicsPath gp = new GraphicsPath())
            {
                float em = f.SizeInPoints * g.DpiY / 72f;
                gp.AddString(s, f.FontFamily, (int)f.Style, em, r, sf);
                float pw2 = f.SizeInPoints < 8.6f ? 1.15f : 1.7f;
                using (Pen pen = new Pen(CSH, Math.Max(pw2, pw2 * _s)))
                {
                    pen.LineJoin = LineJoin.Round;
                    g.DrawPath(pen, gp);
                }
                g.FillPath(b, gp);
            }
        }

        /// <summary>不带描边的文字（给小号说明字用，描边会把小字糊住）</summary>
        private void TxtPlain(Graphics g, string s, Font f, Brush b, RectangleF r, StringAlignment al)
        {
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = al;
                sf.LineAlignment = StringAlignment.Center;
                sf.FormatFlags = StringFormatFlags.NoWrap;
                sf.Trimming = StringTrimming.None;
                g.DrawString(s, f, b, r, sf);
            }
        }

        /// <summary>在矩形里画一行字, 垂直居中; al 控制左/右对齐</summary>
        private void TxtIn(Graphics g, string s, Font f, Brush b, RectangleF r, StringAlignment al)
        {
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = al;
                sf.LineAlignment = StringAlignment.Center;
                sf.FormatFlags = StringFormatFlags.NoWrap;
                sf.Trimming = StringTrimming.None;
                TxtR(g, s, f, b, r, sf);
            }
        }

        private void PaintCompact(Graphics g)
        {
            float padL = _glass ? S(13) : S(5);
            float dot = S(8);
            using (SolidBrush sb = new SolidBrush(StatusColor()))
                g.FillEllipse(sb, padL, Height / 2f - dot / 2f, dot, dot);

            if (!Configured)
            {
                using (SolidBrush b = new SolidBrush(Color.FromArgb(235, 236, 200, 96)))
                    TxtIn(g, "右键填 API Key", _fTag, b,
                          new RectangleF(padL + S(15), 0, Width - padL - S(15), Height), StringAlignment.Near);
                return;
            }
            if (_pos.Count == 0 && _totalEq <= 0)
            {
                string t = _tried ? "读取失败" : "读取中...";
                using (SolidBrush b = new SolidBrush(CF))
                    TxtIn(g, t, _fTag, b, new RectangleF(padL + S(15), 0, Width - padL - S(15), Height), StringAlignment.Near);
                return;
            }

            string eq = _mask ? "••••" : _totalEq.ToString("#,0.0", CultureInfo.InvariantCulture);
            string pl = CompactRight();

            float textX = padL + S(15);
            using (SolidBrush b = new SolidBrush(CT))
                TxtIn(g, eq, _fTag, b, new RectangleF(textX, 0, Width - textX, Height), StringAlignment.Near);
            float ew = g.MeasureString(eq, _fTag).Width;
            using (SolidBrush b = new SolidBrush(_pos.Count == 0 ? CF : ColorOf(_upl)))
                TxtIn(g, pl, _fTag, b, new RectangleF(textX + ew + S(12), 0, Width - textX - ew - S(12), Height), StringAlignment.Near);
        }

        private void PaintList(Graphics g)
        {
            float pad = _glass ? S(13) : S(5);
            int headH = HeadH();
            int rowH = RowH();
            float innerW = Width - pad * 2;

            if (!Configured)
            {
                using (SolidBrush b = new SolidBrush(Color.FromArgb(235, 236, 200, 96)))
                    TxtIn(g, "右键 → 填写 API Key", _fName, b,
                          new RectangleF(pad, 0, innerW, Si(7) + headH), StringAlignment.Near);
                return;
            }
            if (_pos.Count == 0 && _totalEq <= 0)
            {
                string t = _tried ? "读取失败，右键重试" : "读取中...";
                using (SolidBrush b = new SolidBrush(CF))
                    TxtIn(g, t, _fName, b, new RectangleF(pad, 0, innerW, Si(7) + headH), StringAlignment.Near);
                return;
            }

            float y = S(7);
            float gap = S(7);
            float moneyX = Width - pad - ColMoney;
            float pctX = moneyX - ColPct - gap;


            string eq = _mask ? "••••" : _totalEq.ToString("#,0.00", CultureInfo.InvariantCulture);
            string pl = Money(_upl, true);
            using (SolidBrush b = new SolidBrush(CLB))
                TxtIn(g, "权益 " + eq, _fName, b, new RectangleF(pad, y, moneyX - pad - S(4), headH), StringAlignment.Near);
            using (SolidBrush b = new SolidBrush(ColorOf(_upl)))
                TxtIn(g, pl, _fNum, b, new RectangleF(moneyX, y, ColMoney, headH), StringAlignment.Far);
            y += headH;

            if (_glass || _light)
            {
                Color lc = _light ? Color.FromArgb(70, 80, 88, 96) : Color.FromArgb(46, 255, 255, 255);
                using (Pen p = new Pen(lc))
                    g.DrawLine(p, pad, y, Width - pad, y);
            }

            // 实时看盘：每个币对一行，与下面的持仓共用三列（名字 | 价格 | 24h涨幅）
            if (_watch)
            {
                List<string> syms;
                Dictionary<string, double> chgs;
                Dictionary<string, double> lasts;
                Dictionary<string, List<Candle>> barsMap;
                lock (_lk)
                {
                    syms = new List<string>(_watchSyms);
                    chgs = new Dictionary<string, double>(_watchChgMap);
                    lasts = new Dictionary<string, double>(_watchLastMap);
                    barsMap = new Dictionary<string, List<Candle>>(_watchMap);
                }

                int labH = WatchLabH();
                bool any = false;

                foreach (string inst in syms)
                {
                    if (!chgs.ContainsKey(inst)) continue;
                    double chg = chgs[inst];

                    string nm = Short(inst);
                    float nw = g.MeasureString(nm, _fName).Width;
                    using (SolidBrush b = new SolidBrush(CChip))
                        TxtIn(g, nm, _fName, b, new RectangleF(pad, y, nw + S(2), labH), StringAlignment.Near);

                    // 5 分钟 5 根的小 K 线，塞在名字和价格之间
                    List<Candle> cb;
                    if (barsMap.TryGetValue(inst, out cb) && cb != null && cb.Count > 1)
                    {
                        float cx0 = pad + nw + S(6);
                        float cw = pctX - cx0 - S(6);
                        if (cw >= S(16))
                        {
                            DrawKline(g, cb, new RectangleF(cx0, y + S(4), cw, labH - S(8)));
                        }
                    }

                    double lp;
                    if (_watchPrice && lasts.TryGetValue(inst, out lp) && lp > 0)
                    {
                        using (SolidBrush b = new SolidBrush(CT))
                            TxtIn(g, PriceStr(lp), _fNum, b, new RectangleF(pctX, y, ColPct, labH), StringAlignment.Far);
                    }
                    using (SolidBrush b = new SolidBrush(ColorOf(chg)))
                        TxtIn(g, Pct(chg), _fNum, b, new RectangleF(moneyX, y, ColMoney, labH), StringAlignment.Far);

                    y += labH;
                    any = true;
                }

                if (any && _pos.Count > 0)
                {
                    using (Pen p = new Pen(Color.FromArgb(30, 255, 255, 255)))
                        g.DrawLine(p, pad, y - S(1), Width - pad, y - S(1));
                }
            }

            if (_pos.Count == 0)
            {
                using (SolidBrush b = new SolidBrush(CF))
                    TxtIn(g, _tried ? "无持仓" : "读取中...", _fName, b, new RectangleF(pad, y, innerW, rowH), StringAlignment.Near);
                return;
            }

            int n = 0;
            foreach (Pos p in _pos)
            {
                if (n >= 6) break;
                string sideTxt = (p.Side == "short") ? "空" : (p.Side == "long" ? "多" : "");
                Color sc = (p.Side == "short") ? CD : CU;

                float nw = g.MeasureString(p.Name, _fName).Width;
                using (SolidBrush b = new SolidBrush(CName))
                    TxtIn(g, p.Name, _fName, b, new RectangleF(pad, y, nw + S(2), rowH), StringAlignment.Near);
                float sideW = 0;
                if (sideTxt.Length > 0)
                {
                    sideW = g.MeasureString(sideTxt, _fName).Width;
                    using (SolidBrush b = new SolidBrush(sc))
                        TxtIn(g, sideTxt, _fName, b, new RectangleF(pad + nw, y, sideW + S(2), rowH), StringAlignment.Near);
                }



                using (SolidBrush b = new SolidBrush(ColorOf(p.Upl)))
                    TxtIn(g, Pct(p.Ratio), _fNum, b, new RectangleF(pctX, y, ColPct, rowH), StringAlignment.Far);
                using (SolidBrush b = new SolidBrush(ColorOf(p.Upl)))
                    TxtIn(g, Money(p.Upl, true), _fNum, b, new RectangleF(moneyX, y, ColMoney, rowH), StringAlignment.Far);

                y += rowH;
                n++;
            }
        }

        public void DebugInject(List<Pos> ps, double eq, double upl)
        {
            _pos = ps;
            _totalEq = eq;
            _upl = upl;
            _tried = true;
            _online = true;
            Relayout();
            Invalidate();
        }

        public void DebugSetKey()
        {
            _k.Key = "debug-key-1234567890";
            _k.Secret = "debug-secret-1234567890";
            _k.Pass = "debug";
        }

        public void DebugCandles(List<Pos> ps)
        {
            Random r = new Random(7);
            lock (_lk)
            {
                // 给「实时看盘」块造一批假K线
                List<Candle> wb2 = new List<Candle>();
                double wv = 73500;
                for (int i = 0; i < 24; i++)
                {
                    Candle c = new Candle();
                    c.O = wv;
                    c.C = wv + (r.NextDouble() - 0.43) * 40;
                    c.H = Math.Max(c.O, c.C) + r.NextDouble() * 20;
                    c.L = Math.Min(c.O, c.C) - r.NextDouble() * 20;
                    wv = c.C;
                    wb2.Add(c);
                }
                if (_watchSyms.Count == 0) _watchSyms.Add("BTC-USDT-SWAP");
                _watchMap[_watchSyms[0]] = wb2;
                _watchChgMap[_watchSyms[0]] = 0.52;
                _watchLastMap[_watchSyms[0]] = wv;
                if (_watchSyms.Count > 1)
                {
                    _watchMap[_watchSyms[1]] = new List<Candle>(wb2);
                    _watchChgMap[_watchSyms[1]] = -0.86;
                }
            }
            Relayout();
            Invalidate();
        }

        public void DebugGlass(bool v)
        {
            _glass = v;
            ApplyChrome();
            Relayout();
        }


    public class KBar
    {
        public long Ts;
        public double O;
        public double H;
        public double L;
        public double C;
    }

    /// <summary>
    /// 多币种实时K线窗：一个窗口同时看若干个币对，每行一根K线 + 现价/涨跌幅。
    /// 走 OKX 公有行情接口（不需要 API Key）。
    /// 配置 kline-config.ini（币对列表、周期、位置）。
    /// </summary>
    public class KForm : Form
    {
        private Color KCU = Color.FromArgb(255, 96, 96);
        private Color KCD = Color.FromArgb(62, 206, 138);
        private static readonly Color KCF = Color.FromArgb(150, 154, 160);
        private static readonly Color KCT = Color.FromArgb(238, 240, 243);
        private static readonly Color KCB = Color.FromArgb(236, 14, 15, 18);

        private readonly string _dir;
        private readonly string _cfgPath;
        private readonly string _proxy;
        private readonly string _ex;

        private List<string> _syms = new List<string>();
        private readonly Dictionary<string, List<Candle>> _bars = new Dictionary<string, List<Candle>>();
        private readonly Dictionary<string, double> _last = new Dictionary<string, double>();
        private readonly Dictionary<string, double> _chg = new Dictionary<string, double>();
        private readonly Dictionary<string, string> _errs = new Dictionary<string, string>();

        private string _bar = "5m";
        private int _n = 48;
        private int _interval = 1000;
        private bool _glass = true;
        private bool _ma = true;        // 均线总开关（兼容旧配置）
        private bool _ma5 = true;
        private bool _ma10 = true;
        private bool _ma20 = true;
        private bool _boll = false;     // 布林带 BOLL(20,2)
        private bool _sr = false;       // 撑压线（区间高低）
        private bool _busy = false;
        private int _sel = 0;

        private System.Threading.Timer _timer;
        private int _x = -1;
        private int _y = -1;
        private bool _dragging = false;
        private Point _downPt;
        private Point _startPt;
        private ContextMenuStrip _menu;
        private Font _fHead;
        private Font _fName;
        private Font _fNum;
        private readonly Dictionary<string, double> _avgPx = new Dictionary<string, double>();
        private readonly Dictionary<string, double> _liqPx = new Dictionary<string, double>();
        private readonly Dictionary<string, List<double>> _alerts = new Dictionary<string, List<double>>();
        private readonly Dictionary<string, double> _prevPx = new Dictionary<string, double>();
        private readonly Dictionary<string, DateTime> _alertAt = new Dictionary<string, DateTime>();
        private int _tickCount = 0;


        public KForm(string dir)
            : this(dir, "", false, "okx")
        {
        }

        public KForm(string dir, string proxy, bool invert, string ex)
        {
            _dir = dir;
            _cfgPath = Path.Combine(dir, "kline-config.ini");
            _proxy = (proxy == null ? "" : proxy);
            _ex = (ex == "binance") ? "binance" : "okx";
            if (invert)
            {
                Color t = KCU;
                KCU = KCD;
                KCD = t;
            }

            if (_syms.Count == 0)
            {
                _syms.Add("BTC-USDT-SWAP");
                _syms.Add("ETH-USDT-SWAP");
            }
            LoadCfg();
            if (_syms.Count == 0) { _syms.Add("BTC-USDT-SWAP"); }

            _fHead = new Font("Microsoft YaHei", 9.5f, FontStyle.Bold);
            _fName = new Font("Microsoft YaHei", 9f, FontStyle.Bold);
            _fNum = new Font("Consolas", 9f, FontStyle.Bold);

            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            ShowInTaskbar = false;
            DoubleBuffered = true;
            Text = "kline";
            ApplyChrome();

            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            if (_x < 0 || _y < 0 || _x > wa.Right - 100 || _y > wa.Bottom - 80)
            {
                _x = wa.Right - 360;
                _y = wa.Top + 40;
            }
            Location = new Point(_x, _y);
            Size = CalcSize();

            BuildMenu();
            ContextMenuStrip = _menu;

            MouseDown += new MouseEventHandler(OnDown);
            MouseMove += new MouseEventHandler(OnMove);
            MouseUp += new MouseEventHandler(OnUp);
            Resize += new EventHandler(OnResize3);
            Move += delegate { _x = Left; _y = Top; };

            StartTimer();
        }

        private int BlockH() { return 76; }

        private Size CalcSize()
        {
            int w = 360;
            int n = Math.Max(1, Math.Min(_syms.Count, 8));
            int h = 28 + n * BlockH() + 10;
            return new Size(w, h);
        }

        private void OnResize3(object s, EventArgs e)
        {
            if (_glass)
            {
                using (GraphicsPath p = KRounded(new Rectangle(0, 0, Width, Height), 10))
                {
                    Region old = this.Region;
                    this.Region = new Region(p);
                    if (old != null) old.Dispose();
                }
            }
            else
            {
                Region old = this.Region;
                this.Region = null;
                if (old != null) old.Dispose();
            }
        }

        private static GraphicsPath KRounded(Rectangle r, int rad)
        {
            GraphicsPath p = new GraphicsPath();
            int d = rad * 2;
            if (r.Width <= d || r.Height <= d) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        private void ApplyChrome()
        {
            if (_glass)
            {
                BackColor = Color.FromArgb(14, 15, 18);
                TransparencyKey = Color.Empty;
            }
            else
            {
                BackColor = Color.Black;
                TransparencyKey = Color.Black;
            }
            Cursor = Cursors.Hand;
        }

        private void OnDown(object s, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                _dragging = true;
                _downPt = Control.MousePosition;
                _startPt = Location;
                int idx = (e.Y - 30) / BlockH();
                if (idx >= 0 && idx < _syms.Count) { _sel = idx; Invalidate(); }
            }
        }

        private void OnMove(object s, MouseEventArgs e)
        {
            if (_dragging)
            {
                Point p = Control.MousePosition;
                Location = new Point(_startPt.X + (p.X - _downPt.X), _startPt.Y + (p.Y - _downPt.Y));
            }
        }

        private void OnUp(object s, MouseEventArgs e)
        {
            if (_dragging)
            {
                _dragging = false;
                _x = Left;
                _y = Top;
                SaveCfg();
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (_timer != null) _timer.Dispose();
            _x = Left;
            _y = Top;
            SaveCfg();
            base.OnFormClosing(e);
        }

        private void StartTimer()
        {
            if (_timer != null) _timer.Dispose();
            _timer = new System.Threading.Timer(Tick, null, 150, _interval);
        }

        private void Tick(object st)
        {
            if (_busy) return;
            _busy = true;
            try
            {
                List<string> cur = new List<string>(_syms);
                foreach (string inst in cur)
                {
                    try
                    {
                        string body = Fetch(inst);
                        string code = KStr(body, "code");
                        if (code.Length > 0 && code != "0")
                        {
                            lock (_bars) { _errs[inst] = code + " " + KStr(body, "msg"); }
                            continue;
                        }
                        List<Candle> cs = Board.ParseKlineRows(body);
                        if (cs.Count > 1)
                        {
                            lock (_bars)
                            {
                                _bars[inst] = cs;
                                _last[inst] = cs[cs.Count - 1].C;
                                _chg[inst] = cs[0].O > 0 ? (cs[cs.Count - 1].C - cs[0].O) / cs[0].O * 100.0 : 0;
                                _errs[inst] = "";
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        lock (_bars) { _errs[inst] = ex.Message; }
                    }
                }
            }
            finally
            {
                _busy = false;
            }
            _tickCount++;
            if (_tickCount <= 1 || _tickCount % 5 == 0) RefreshPos();
            CheckAlerts();
            Redraw();
        }

        /// <summary>从主窗共享的持仓快照里拿开仓价/强平价（K线窗自己不做签名）</summary>
        private void RefreshPos()
        {
            try
            {
                List<Pos> ps = Board.SnapshotPositions();
                lock (_bars)
                {
                    _avgPx.Clear();
                    _liqPx.Clear();
                    foreach (Pos p in ps)
                    {
                        if (p.AvgPx > 0) _avgPx[p.InstId] = p.AvgPx;
                        if (p.LiqPx > 0) _liqPx[p.InstId] = p.LiqPx;
                    }
                }
            }
            catch { }
        }

        /// <summary>价格穿过提醒线就叫一声（每 60 秒最多一次）</summary>
        private void CheckAlerts()
        {
            List<string> keys;
            lock (_bars) { keys = new List<string>(_alerts.Keys); }
            foreach (string inst in keys)
            {
                double now;
                if (!_last.TryGetValue(inst, out now)) continue;
                double prev;
                if (!_prevPx.TryGetValue(inst, out prev)) { _prevPx[inst] = now; continue; }
                List<double> lv;
                lock (_bars) { if (!_alerts.TryGetValue(inst, out lv) || lv == null) continue; else lv = new List<double>(lv); }
                foreach (double px in lv)
                {
                    bool crossed = (prev < px && now >= px) || (prev > px && now <= px);
                    if (!crossed) continue;
                    DateTime at;
                    if (_alertAt.TryGetValue(inst + "@" + px, out at) && (DateTime.UtcNow - at).TotalSeconds < 60) continue;
                    _alertAt[inst + "@" + px] = DateTime.UtcNow;
                    try { System.Media.SystemSounds.Exclamation.Play(); } catch { }
                    Redraw();
                }
                _prevPx[inst] = now;
            }
        }
        private string Fetch(string inst)
        {
            // 公有行情，不需要 API Key（OKX / 币安各走各的接口）
            return Board.HttpGet(Board.KlineUrl(_ex, inst, _bar, _n), _proxy);
        }

        private static string KStr(string json, string key)
        {
            if (json == null) return "";
            Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : "";
        }

        private void Redraw()
        {
            if (this.IsHandleCreated && !this.IsDisposed)
                this.BeginInvoke((MethodInvoker)delegate { Invalidate(); });
        }

        private void BuildMenu()
        {
            _menu = new ContextMenuStrip();
            _menu.Font = new Font("Microsoft YaHei", 9f);

            ToolStripMenuItem miAdd = new ToolStripMenuItem("添加币对");
            miAdd.DropDownOpening += delegate
            {
                miAdd.DropDownItems.Clear();
                foreach (string id in Candidates())
                {
                    string sid = id;
                    ToolStripMenuItem it = new ToolStripMenuItem(Short(id));
                    it.Checked = _syms.Contains(sid);
                    it.Click += delegate
                    {
                        if (_syms.Contains(sid)) { _syms.Remove(sid); }
                        else if (_syms.Count < 8) { _syms.Add(sid); }
                        _sel = Math.Max(0, Math.Min(_sel, _syms.Count - 1));
                        ApplySize();
                        SaveCfg();
                        Tick(null);
                        Invalidate();
                    };
                    miAdd.DropDownItems.Add(it);
                }
                miAdd.DropDownItems.Add(new ToolStripSeparator());
                ToolStripMenuItem diy = new ToolStripMenuItem("自定义币对…");
                diy.Click += delegate { AddDialog(); };
                miAdd.DropDownItems.Add(diy);
            };
            _menu.Items.Add(miAdd);

            ToolStripMenuItem miDel = new ToolStripMenuItem("移除当前币对");
            miDel.Click += delegate
            {
                if (_syms.Count > 0 && _sel >= 0 && _sel < _syms.Count)
                {
                    _syms.RemoveAt(_sel);
                    _sel = Math.Max(0, Math.Min(_sel, _syms.Count - 1));
                    ApplySize();
                    SaveCfg();
                    Invalidate();
                }
            };
            _menu.Items.Add(miDel);

            ToolStripMenuItem miBar = new ToolStripMenuItem("周期");
            string[] bars = new string[] { "1m", "5m", "15m", "1H", "4H", "1D" };
            string[] names = new string[] { "1 分钟", "5 分钟", "15 分钟", "1 小时", "4 小时", "1 天" };
            for (int i = 0; i < bars.Length; i++)
            {
                string bv = bars[i];
                ToolStripMenuItem it = new ToolStripMenuItem(names[i]);
                it.Click += delegate { _bar = bv; SaveCfg(); StartTimer(); Tick(null); };
                miBar.DropDownItems.Add(it);
            }
            _menu.Items.Add(miBar);

            ToolStripMenuItem miInt = new ToolStripMenuItem("刷新频率");
            int[] iv = new int[] { 1000, 2000, 3000, 5000 };
            for (int i = 0; i < iv.Length; i++)
            {
                int vv = iv[i];
                ToolStripMenuItem it = new ToolStripMenuItem((vv / 1000.0).ToString("0.#") + " 秒");
                it.Click += delegate { _interval = vv; SaveCfg(); StartTimer(); };
                miInt.DropDownItems.Add(it);
            }
            _menu.Items.Add(miInt);

            ToolStripMenuItem miN = new ToolStripMenuItem("K线根数");
            int[] kns = new int[] { 30, 48, 80, 120, 200, 300 };
            foreach (int kv in kns)
            {
                int kkn = kv;
                ToolStripMenuItem it = new ToolStripMenuItem(kkn + " 根");
                it.Checked = (kkn == _n);
                it.Click += delegate
                {
                    _n = kkn;
                    SaveCfg();
                    Tick(null);
                    Invalidate();
                };
                miN.DropDownItems.Add(it);
            }
            miN.DropDownItems.Add(new ToolStripSeparator());
            ToolStripMenuItem diyN = new ToolStripMenuItem("自定义根数…");
            diyN.Click += delegate
            {
                Form d = new Form();
                d.Text = "K线根数";
                d.FormBorderStyle = FormBorderStyle.FixedDialog;
                d.StartPosition = FormStartPosition.CenterScreen;
                d.MaximizeBox = false;
                d.MinimizeBox = false;
                d.ClientSize = new Size(320, 120);
                d.TopMost = true;
                d.Font = new Font("Microsoft YaHei", 9f);
                Label lb = new Label();
                lb.Text = "20 ~ 300 根（OKX 单次上限 300）";
                lb.AutoSize = false;
                lb.SetBounds(16, 12, 288, 20);
                d.Controls.Add(lb);
                TextBox tb = new TextBox();
                tb.Text = _n.ToString();
                tb.SetBounds(16, 40, 288, 24);
                d.Controls.Add(tb);
                Button ok = new Button();
                ok.Text = "确定";
                ok.SetBounds(150, 78, 72, 28);
                ok.DialogResult = DialogResult.OK;
                d.Controls.Add(ok);
                Button cancel = new Button();
                cancel.Text = "取消";
                cancel.SetBounds(232, 78, 72, 28);
                cancel.DialogResult = DialogResult.Cancel;
                d.Controls.Add(cancel);
                d.AcceptButton = ok;
                d.CancelButton = cancel;
                try
                {
                    if (d.ShowDialog(this) == DialogResult.OK)
                    {
                        int nv;
                        if (int.TryParse(tb.Text.Trim(), out nv))
                        {
                            _n = Math.Max(20, Math.Min(300, nv));
                            SaveCfg();
                            Tick(null);
                            Invalidate();
                        }
                    }
                }
                finally { d.Dispose(); }
            };
            miN.DropDownItems.Add(diyN);
            _menu.Items.Add(miN);

            ToolStripMenuItem miAux = new ToolStripMenuItem("辅助线（可自由勾选）");
            miAux.DropDownOpening += delegate
            {
                miAux.DropDownItems.Clear();
                ToolStripMenuItem a1 = new ToolStripMenuItem("均线 MA5");
                a1.Checked = _ma5;
                a1.Click += delegate { a1.Checked = !a1.Checked; _ma5 = a1.Checked; SaveCfg(); Invalidate(); };
                miAux.DropDownItems.Add(a1);

                ToolStripMenuItem a2 = new ToolStripMenuItem("均线 MA10");
                a2.Checked = _ma10;
                a2.Click += delegate { a2.Checked = !a2.Checked; _ma10 = a2.Checked; SaveCfg(); Invalidate(); };
                miAux.DropDownItems.Add(a2);

                ToolStripMenuItem a3 = new ToolStripMenuItem("均线 MA20");
                a3.Checked = _ma20;
                a3.Click += delegate { a3.Checked = !a3.Checked; _ma20 = a3.Checked; SaveCfg(); Invalidate(); };
                miAux.DropDownItems.Add(a3);

                miAux.DropDownItems.Add(new ToolStripSeparator());

                ToolStripMenuItem a4 = new ToolStripMenuItem("布林带 BOLL(20,2)");
                a4.Checked = _boll;
                a4.Click += delegate { a4.Checked = !a4.Checked; _boll = a4.Checked; SaveCfg(); Invalidate(); };
                miAux.DropDownItems.Add(a4);

                ToolStripMenuItem a5 = new ToolStripMenuItem("撑压线（区间高低）");
                a5.Checked = _sr;
                a5.Click += delegate { a5.Checked = !a5.Checked; _sr = a5.Checked; SaveCfg(); Invalidate(); };
                miAux.DropDownItems.Add(a5);
            };
            _menu.Items.Add(miAux);

            ToolStripMenuItem miAlert = new ToolStripMenuItem("价格提醒");
            miAlert.DropDownOpening += delegate
            {
                miAlert.DropDownItems.Clear();
                string cur = (_sel >= 0 && _sel < _syms.Count) ? _syms[_sel] : (_syms.Count > 0 ? _syms[0] : "");
                ToolStripMenuItem add = new ToolStripMenuItem("给「" + Short(cur) + "」加提醒…");
                add.Click += delegate { AddAlertDialog(cur); };
                miAlert.DropDownItems.Add(add);

                List<double> curAl = null;
                lock (_bars) { if (cur.Length > 0 && _alerts.ContainsKey(cur)) curAl = new List<double>(_alerts[cur]); }
                if (curAl != null && curAl.Count > 0)
                {
                    ToolStripMenuItem clr = new ToolStripMenuItem("清除「" + Short(cur) + "」的提醒");
                    clr.Click += delegate
                    {
                        lock (_bars) { _alerts.Remove(cur); }
                        SaveCfg();
                        Invalidate();
                    };
                    miAlert.DropDownItems.Add(clr);
                }
                miAlert.DropDownItems.Add(new ToolStripSeparator());
                ToolStripMenuItem clrAll = new ToolStripMenuItem("清除全部提醒");
                clrAll.Click += delegate
                {
                    lock (_bars) { _alerts.Clear(); }
                    SaveCfg();
                    Invalidate();
                };
                miAlert.DropDownItems.Add(clrAll);

                if (curAl != null)
                {
                    foreach (double pv in curAl)
                    {
                        double pp = pv;
                        ToolStripMenuItem it = new ToolStripMenuItem("· " + pp.ToString("#,0.####", CultureInfo.InvariantCulture));
                        it.Enabled = false;
                        miAlert.DropDownItems.Add(it);
                    }
                }
            };
            _menu.Items.Add(miAlert);

            ToolStripMenuItem miGlass = new ToolStripMenuItem("深色底板");
            miGlass.Checked = _glass;
            miGlass.Click += delegate
            {
                miGlass.Checked = !_glass;
                _glass = miGlass.Checked;
                bool vis = Visible;
                if (vis) Hide();
                ApplyChrome();
                if (vis) { Show(); TopMost = true; }
                SaveCfg();
                Invalidate();
            };
            _menu.Items.Add(miGlass);

            _menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem miRef = new ToolStripMenuItem("立即刷新");
            miRef.Click += delegate { Tick(null); };
            _menu.Items.Add(miRef);

            ToolStripMenuItem miHide = new ToolStripMenuItem("隐藏K线窗");
            miHide.Click += delegate { Hide(); };
            _menu.Items.Add(miHide);
        }

        private void ApplySize()
        {
            Size s = CalcSize();
            if (Width != s.Width || Height != s.Height) Size = s;
        }

        private static string Short(string instId)
        {
            if (instId.EndsWith("-USDT-SWAP")) return instId.Replace("-USDT-SWAP", "");
            if (instId.EndsWith("-USDC-SWAP")) return instId.Replace("-USDC-SWAP", "");
            if (instId.EndsWith("-SWAP")) return instId.Replace("-SWAP", "");
            return instId;
        }

        /// <summary>可选币对：默认几个 + 已经添加的</summary>
        private List<string> Candidates()
        {
            List<string> res = new List<string>();
            res.Add("BTC-USDT-SWAP");
            res.Add("ETH-USDT-SWAP");
            foreach (string s in _syms) if (!res.Contains(s)) res.Add(s);
            return res;
        }

        /// <summary>给某个品种加一条价格提醒线</summary>
        private void AddAlertDialog(string inst)
        {
            if (inst == null || inst.Length == 0) return;
            Form d = new Form();
            d.Text = "价格提醒 · " + Short(inst);
            d.FormBorderStyle = FormBorderStyle.FixedDialog;
            d.StartPosition = FormStartPosition.CenterScreen;
            d.MaximizeBox = false;
            d.MinimizeBox = false;
            d.ClientSize = new Size(330, 130);
            d.TopMost = true;
            d.Font = new Font("Microsoft YaHei", 9f);

            Label lb = new Label();
            lb.Text = "价格穿过这条线时会响一声（同一条线 60 秒内只响一次）";
            lb.AutoSize = false;
            lb.SetBounds(14, 10, 302, 34);
            d.Controls.Add(lb);

            TextBox tb = new TextBox();
            double cur;
            tb.Text = _last.TryGetValue(inst, out cur) && cur > 0 ? cur.ToString("#,0.####", CultureInfo.InvariantCulture) : "";
            tb.SetBounds(14, 46, 302, 24);
            d.Controls.Add(tb);

            Button ok = new Button();
            ok.Text = "添加";
            ok.SetBounds(154, 84, 76, 28);
            ok.DialogResult = DialogResult.OK;
            d.Controls.Add(ok);
            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.SetBounds(240, 84, 76, 28);
            cancel.DialogResult = DialogResult.Cancel;
            d.Controls.Add(cancel);
            d.AcceptButton = ok;
            d.CancelButton = cancel;

            try
            {
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    double v;
                    if (double.TryParse(tb.Text.Trim().Replace(",", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v > 0)
                    {
                        lock (_bars)
                        {
                            if (!_alerts.ContainsKey(inst)) _alerts[inst] = new List<double>();
                            if (!_alerts[inst].Contains(v)) _alerts[inst].Add(v);
                        }
                        SaveCfg();
                        Invalidate();
                    }
                }
            }
            finally { d.Dispose(); }
        }

        private void AddDialog()
        {
            Form d = new Form();
            d.Text = "添加币对";
            d.FormBorderStyle = FormBorderStyle.FixedDialog;
            d.StartPosition = FormStartPosition.CenterScreen;
            d.MaximizeBox = false;
            d.MinimizeBox = false;
            d.ClientSize = new Size(420, 150);
            d.TopMost = true;
            d.Font = new Font("Microsoft YaHei", 10f);

            Label l = new Label();
            l.Text = "填 OKX 永续合约 id，多个用逗号分隔，例如：\r\nBTC-USDT-SWAP, DOGE-USDT-SWAP";
            l.AutoSize = false;
            l.SetBounds(16, 12, 388, 40);
            d.Controls.Add(l);

            TextBox tb = new TextBox();
            tb.Text = "";
            tb.Font = new Font("Consolas", 10f);
            tb.SetBounds(16, 56, 388, 26);
            d.Controls.Add(tb);

            Button ok = new Button();
            ok.Text = "添加";
            ok.SetBounds(240, 104, 78, 30);
            ok.DialogResult = DialogResult.OK;
            d.Controls.Add(ok);

            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.SetBounds(326, 104, 78, 30);
            cancel.DialogResult = DialogResult.Cancel;
            d.Controls.Add(cancel);

            d.AcceptButton = ok;
            d.CancelButton = cancel;

            try
            {
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    string[] parts = tb.Text.Split(new char[] { ',', '，', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (string s in parts)
                    {
                        string id = s.Trim().ToUpper();
                        if (id.Length > 3 && !_syms.Contains(id) && _syms.Count < 8) _syms.Add(id);
                    }
                    ApplySize();
                    SaveCfg();
                    Tick(null);
                    Invalidate();
                }
            }
            finally { d.Dispose(); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;

            if (_glass)
            {
                using (GraphicsPath p = KRounded(new Rectangle(0, 0, Width, Height), 10))
                using (SolidBrush bg = new SolidBrush(KCB))
                    g.FillPath(bg, p);
                using (GraphicsPath p2 = KRounded(new Rectangle(0, 0, Width - 1, Height - 1), 10))
                using (Pen pen = new Pen(Color.FromArgb(44, 255, 255, 255)))
                    g.DrawPath(pen, p2);
            }

            int pad = 8;
            using (SolidBrush b = new SolidBrush(KCF))
                g.DrawString("实时看盘 · " + _bar + " · " + _syms.Count + " 个", _fHead, b, new PointF(pad, 6));

            {
                List<string> lbl = new List<string>();
                List<Color> lc = new List<Color>();
                if (_ma5) { lbl.Add("MA5"); lc.Add(MA5C); }
                if (_ma10) { lbl.Add("MA10"); lc.Add(MA10C); }
                if (_ma20) { lbl.Add("MA20"); lc.Add(MA20C); }
                if (_boll) { lbl.Add("BOLL"); lc.Add(BOLLC); }
                if (_sr) { lbl.Add("撑压"); lc.Add(SRC); }
                float lx = Width - pad;
                for (int k = lbl.Count - 1; k >= 0; k--)
                {
                    float lw = g.MeasureString(lbl[k], _fNum).Width;
                    lx -= lw;
                    using (SolidBrush b = new SolidBrush(lc[k]))
                        g.DrawString(lbl[k], _fNum, b, new PointF(lx, 7));
                    lx -= 9;
                }
            }

            int headH = 30;
            int blockH = BlockH();
            int chartH = blockH - 24;

            for (int i = 0; i < _syms.Count && i < 8; i++)
            {
                string inst = _syms[i];
                float y = headH + i * blockH;

                if (i == _sel)
                {
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb(30, 120, 170, 240)))
                        g.FillRectangle(sb, 2, y, Width - 4, blockH - 2);
                }

                List<Candle> cs = null;
                double last = 0, chg = 0;
                string err = "";
                lock (_bars)
                {
                    if (_bars.ContainsKey(inst)) cs = _bars[inst];
                    if (_last.ContainsKey(inst)) last = _last[inst];
                    if (_chg.ContainsKey(inst)) chg = _chg[inst];
                    if (_errs.ContainsKey(inst)) err = _errs[inst];
                }

                using (SolidBrush b = new SolidBrush(KCT))
                    g.DrawString(Short(inst), _fName, b, new PointF(pad, y));

                if (cs != null && cs.Count > 1)
                {
                    string ps = last.ToString("#,0.##", CultureInfo.InvariantCulture);
                    string cs2 = (chg >= 0 ? "+" : "") + chg.ToString("0.00", CultureInfo.InvariantCulture) + "%";
                    float pw = g.MeasureString(ps, _fNum).Width;
                    using (SolidBrush b = new SolidBrush(KCT))
                        g.DrawString(ps, _fNum, b, new PointF(Width - pad - pw, y));
                    float cw = g.MeasureString(cs2, _fNum).Width;
                    using (SolidBrush b = new SolidBrush(chg >= 0 ? KCU : KCD))
                        g.DrawString(cs2, _fNum, b, new PointF(Width - pad - pw - 8 - cw, y));

                    DrawMini(g, cs, new RectangleF(pad, y + 18, Width - pad * 2, chartH), inst);
                }
                else
                {
                    using (SolidBrush b = new SolidBrush(KCF))
                        g.DrawString(err.Length > 0 ? err : "读取中...", _fName, b, new PointF(pad + 60, y));
                }
            }
        }

        private static readonly Color MA5C = Color.FromArgb(255, 205, 90);
        private static readonly Color MA10C = Color.FromArgb(110, 190, 255);
        private static readonly Color MA20C = Color.FromArgb(200, 150, 255);

        /// <summary>在图表区画一条均线（MA5/10/20）</summary>
        private void DrawMA(Graphics g, List<Candle> cs, RectangleF r, double lo, double span, int period, Color col)
        {
            if (cs.Count < period + 1) return;
            float step = r.Width / cs.Count;
            Pen pen = null;
            try
            {
                pen = new Pen(Color.FromArgb(235, col), 1.5f);
                PointF prev = PointF.Empty;
                bool has = false;
                double sum = 0;
                for (int i = 0; i < cs.Count; i++)
                {
                    sum += cs[i].C;
                    if (i >= period) sum -= cs[i - period].C;
                    if (i < period - 1) continue;
                    double ma = sum / period;
                    float x = r.X + (i + 0.5f) * step;
                    float y = r.Bottom - (float)((ma - lo) / span * (r.Height - 2)) - 1;
                    if (has) g.DrawLine(pen, prev, new PointF(x, y));
                    prev = new PointF(x, y);
                    has = true;
                }
            }
            finally { if (pen != null) pen.Dispose(); }
        }

        private static readonly Color BOLLC = Color.FromArgb(120, 200, 160);
        private static readonly Color SRC = Color.FromArgb(210, 170, 120);

        /// <summary>布林带 BOLL(20,2)：中轨 MA20 + 上下轨 ±2σ</summary>
        private void DrawBoll(Graphics g, List<Candle> cs, RectangleF r, double lo, double span)
        {
            int period = 20;
            if (cs.Count < period + 1) return;
            float step = r.Width / cs.Count;
            PointF[] mid = new PointF[cs.Count];
            PointF[] up = new PointF[cs.Count];
            PointF[] dn = new PointF[cs.Count];
            bool[] ok = new bool[cs.Count];
            for (int i = period - 1; i < cs.Count; i++)
            {
                double sum = 0, sum2 = 0;
                for (int j = i - period + 1; j <= i; j++) { sum += cs[j].C; sum2 += cs[j].C * cs[j].C; }
                double ma = sum / period;
                double var = Math.Max(0, sum2 / period - ma * ma);
                double sd = Math.Sqrt(var);
                float x = r.X + (i + 0.5f) * step;
                mid[i] = new PointF(x, MapY(ma, r, lo, span));
                up[i] = new PointF(x, MapY(ma + 2 * sd, r, lo, span));
                dn[i] = new PointF(x, MapY(ma - 2 * sd, r, lo, span));
                ok[i] = true;
            }
            using (Pen pu = new Pen(Color.FromArgb(170, BOLLC), 1f))
            using (Pen pd = new Pen(Color.FromArgb(170, BOLLC), 1f))
            using (Pen pm = new Pen(Color.FromArgb(120, BOLLC), 1f))
            {
                pu.DashStyle = DashStyle.Dash;
                pd.DashStyle = DashStyle.Dash;
                for (int i = period; i < cs.Count; i++)
                {
                    if (!ok[i - 1] || !ok[i]) continue;
                    g.DrawLine(pu, up[i - 1], up[i]);
                    g.DrawLine(pd, dn[i - 1], dn[i]);
                    g.DrawLine(pm, mid[i - 1], mid[i]);
                }
            }
        }

        private float MapY(double price, RectangleF r, double lo, double span)
        {
            return r.Bottom - (float)((price - lo) / span * (r.Height - 2)) - 1;
        }

        /// <summary>撑压线：取可见区间的最高/最低价画两条水平虚线</summary>
        private void DrawSR(Graphics g, List<Candle> cs, RectangleF r, double lo, double span)
        {
            if (cs.Count < 3) return;
            double hi = double.MinValue, lo2 = double.MaxValue;
            int n = Math.Min(cs.Count, 120);
            for (int i = cs.Count - n; i < cs.Count; i++)
            {
                if (cs[i].H > hi) hi = cs[i].H;
                if (cs[i].L < lo2) lo2 = cs[i].L;
            }
            using (Pen p = new Pen(Color.FromArgb(180, SRC), 1f))
            {
                p.DashStyle = DashStyle.Dash;
                float yh = MapY(hi, r, lo, span);
                float yl = MapY(lo2, r, lo, span);
                g.DrawLine(p, r.X, yh, r.Right, yh);
                g.DrawLine(p, r.X, yl, r.Right, yl);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(200, SRC)))
                {
                    g.DrawString("压", _fNum, b, new PointF(r.X + 3, yh + 1));
                    g.DrawString("撑", _fNum, b, new PointF(r.X + 3, yl - 14));
                }
            }
        }

        /// <summary>画一条价位线（开仓/强平/提醒）</summary>
        private void DrawLevel(Graphics g, RectangleF r, double lo, double span, double price,
            Color col, string tag, bool thick)
        {
            if (price <= 0 || span <= 0) return;
            float y = r.Bottom - (float)((price - lo) / span * (r.Height - 2)) - 1;
            if (y < r.Top - 2 || y > r.Bottom + 2) return;
            using (Pen p = new Pen(col, thick ? 1.6f : 1.1f))
            {
                p.DashStyle = DashStyle.Dash;
                g.DrawLine(p, r.X, y, r.Right, y);
            }
            using (SolidBrush b = new SolidBrush(col))
            {
                float tw = g.MeasureString(tag, _fNum).Width;
                g.DrawString(tag, _fNum, b, new PointF(r.Right - tw - 2, y + 1));
            }
        }

        private void DrawMini(Graphics g, List<Candle> cs, RectangleF r, string inst)
        {
            if (r.Width < 10 || r.Height < 6 || cs.Count < 2) return;
            double hi = double.MinValue, lo = double.MaxValue;
            foreach (Candle c in cs)
            {
                if (c.H > hi) hi = c.H;
                if (c.L < lo) lo = c.L;
            }
            if (hi <= lo) return;
            double span = hi - lo;
            float step = r.Width / cs.Count;
            float bw = Math.Max(1f, step * 0.62f);
            for (int i = 0; i < cs.Count; i++)
            {
                Candle c = cs[i];
                float xc = r.X + i * step + step / 2f;
                float yh = r.Bottom - (float)((c.H - lo) / span * (r.Height - 2)) - 1;
                float yl = r.Bottom - (float)((c.L - lo) / span * (r.Height - 2)) - 1;
                float yo = r.Bottom - (float)((c.O - lo) / span * (r.Height - 2)) - 1;
                float yc = r.Bottom - (float)((c.C - lo) / span * (r.Height - 2)) - 1;
                Color col = (c.C >= c.O) ? KCU : KCD;
                using (Pen p = new Pen(col, 1f))
                    g.DrawLine(p, xc, yh, xc, yl);
                float ty = Math.Min(yo, yc);
                float th = Math.Max(1f, Math.Abs(yc - yo));
                using (SolidBrush bb = new SolidBrush(col))
                    g.FillRectangle(bb, xc - bw / 2f, ty, bw, th);
            }

            // 价位线：开仓 / 强平 / 价格提醒
            double ap, lp2;
            lock (_bars)
            {
                if (_avgPx.TryGetValue(inst, out ap) && ap > 0)
                    DrawLevel(g, r, lo, span, ap, Color.FromArgb(200, 200, 205, 215), "开", false);
                if (_liqPx.TryGetValue(inst, out lp2) && lp2 > 0)
                    DrawLevel(g, r, lo, span, lp2, Color.FromArgb(220, 255, 90, 90), "强平", true);
                List<double> al;
                if (_alerts.TryGetValue(inst, out al) && al != null)
                {
                    foreach (double px in al)
                        DrawLevel(g, r, lo, span, px, Color.FromArgb(230, 90, 210, 255), "提醒", true);
                }
            }

            if (_boll) DrawBoll(g, cs, r, lo, span);
            if (_ma5) DrawMA(g, cs, r, lo, span, 5, MA5C);
            if (_ma10) DrawMA(g, cs, r, lo, span, 10, MA10C);
            if (_ma20) DrawMA(g, cs, r, lo, span, 20, MA20C);
            if (_sr) DrawSR(g, cs, r, lo, span);
        }

        private void LoadCfg()
        {
            try
            {
                if (!File.Exists(_cfgPath)) return;
                foreach (string line in File.ReadAllLines(_cfgPath))
                {
                    string ln = line.Trim();
                    if (ln.Length == 0 || ln.StartsWith("#")) continue;
                    int i = ln.IndexOf('=');
                    if (i <= 0) continue;
                    string k = ln.Substring(0, i).Trim().ToLower();
                    string v = ln.Substring(i + 1).Trim();
                    if (k == "symbols" && v.Length > 0)
                    {
                        _syms.Clear();
                        foreach (string s in v.Split(new char[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                        {
                            string id = s.Trim().ToUpper();
                            if (id.Length > 3 && !_syms.Contains(id) && _syms.Count < 8) _syms.Add(id);
                        }
                    }
                    else if (k == "bar" && v.Length > 0) _bar = v;
                    else if (k == "n") { int t; if (int.TryParse(v, out t)) _n = Math.Max(20, Math.Min(200, t)); }
                    else if (k == "interval") { int t; if (int.TryParse(v, out t)) _interval = Math.Max(500, t); }
                    else if (k == "glass") _glass = (v == "1");
                    else if (k == "ma") { _ma = (v == "1"); _ma5 = _ma; _ma10 = _ma; _ma20 = _ma; }
                    else if (k == "ma5") _ma5 = (v == "1");
                    else if (k == "ma10") _ma10 = (v == "1");
                    else if (k == "ma20") _ma20 = (v == "1");
                    else if (k == "boll") _boll = (v == "1");
                    else if (k == "sr") _sr = (v == "1");
                    else if (k == "alerts" && v.Length > 0)
                    {
                        foreach (string part in v.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                        {
                            int c = part.LastIndexOf(':');
                            if (c <= 0) continue;
                            string ii = part.Substring(0, c).Trim().ToUpper();
                            double pv;
                            if (!double.TryParse(part.Substring(c + 1).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out pv)) continue;
                            if (pv <= 0) continue;
                            if (!_alerts.ContainsKey(ii)) _alerts[ii] = new List<double>();
                            _alerts[ii].Add(pv);
                        }
                    }
                    else if (k == "x") { int t; if (int.TryParse(v, out t)) _x = t; }
                    else if (k == "y") { int t; if (int.TryParse(v, out t)) _y = t; }
                }
            }
            catch { }
        }

        private void SaveCfg()
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("# 多币种实时K线窗");
                sb.AppendLine("ma=" + ((_ma5 || _ma10 || _ma20) ? "1" : "0"));
                sb.AppendLine("ma5=" + (_ma5 ? "1" : "0"));
                sb.AppendLine("ma10=" + (_ma10 ? "1" : "0"));
                sb.AppendLine("ma20=" + (_ma20 ? "1" : "0"));
                sb.AppendLine("boll=" + (_boll ? "1" : "0"));
                sb.AppendLine("sr=" + (_sr ? "1" : "0"));
                StringBuilder al2 = new StringBuilder();
                foreach (KeyValuePair<string, List<double>> kv in _alerts)
                {
                    foreach (double pv in kv.Value)
                    {
                        if (al2.Length > 0) al2.Append(",");
                        al2.Append(kv.Key).Append(":").Append(pv.ToString(CultureInfo.InvariantCulture));
                    }
                }
                sb.AppendLine("# 价格提醒：instId:价格，逗号分隔");
                sb.AppendLine("alerts=" + al2.ToString());
                sb.AppendLine("symbols=" + string.Join(",", _syms.ToArray()));
                sb.AppendLine("bar=" + _bar);
                sb.AppendLine("n=" + _n);
                sb.AppendLine("interval=" + _interval);
                sb.AppendLine("glass=" + (_glass ? "1" : "0"));
                sb.AppendLine("x=" + _x);
                sb.AppendLine("y=" + _y);
                File.WriteAllText(_cfgPath, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }

        /// <summary>自检用：给若干币对灌假K线并绘制</summary>
        public void DebugBars(int count)
        {
            Random r = new Random(11);
            lock (_bars)
            {
                for (int k = 0; k < _syms.Count; k++)
                {
                    List<Candle> list = new List<Candle>();
                    double basePx = 1000 + k * 1500;
                    double v = basePx * 0.99;
                    for (int i = 0; i < count; i++)
                    {
                        Candle c = new Candle();
                        c.O = v;
                        c.C = v + (r.NextDouble() - 0.45) * basePx * 0.004;
                        c.H = Math.Max(c.O, c.C) + r.NextDouble() * basePx * 0.0016;
                        c.L = Math.Min(c.O, c.C) - r.NextDouble() * basePx * 0.0016;
                        v = c.C;
                        list.Add(c);
                    }
                    _bars[_syms[k]] = list;
                    _last[_syms[k]] = v;
                    _chg[_syms[k]] = (r.NextDouble() - 0.4) * 4;
                    _errs[_syms[k]] = "";
                }
            }
            Invalidate();
        }
    }
    }
}
'@

if (-not ("OkxPnl.Board" -as [type])) {
    Add-Type -TypeDefinition $code -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Security.dll')
}

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($SelfTest) {
    Write-Output '--- 1. 签名 ---'
    $sig = [OkxPnl.Board]::Sign('secret', '2020-12-08T09:08:57.715ZGET/api/v5/account/balance')
    Write-Output ("  长度=" + $sig.Length + " (应为44)  " + $sig.Substring(0, 12) + "...")

    Write-Output '--- 2. 持仓解析 ---'
    $pj = '{"code":"0","msg":"","data":[{"instType":"SWAP","mgnMode":"cross","posId":"1","posSide":"long","pos":"0.5","instId":"BTC-USDT-SWAP","lever":"10","avgPx":"95000","markPx":"96200","upl":"600.5","uplRatio":"0.1263"},{"instType":"SWAP","mgnMode":"cross","posId":"2","posSide":"short","pos":"10","instId":"ETH-USDT-SWAP","lever":"5","avgPx":"3200","markPx":"3182.4","upl":"-176","uplRatio":"-0.0289"}]}'
    $ps = [OkxPnl.Board]::ParsePositions($pj)
    foreach ($p in $ps) {
        Write-Output ("  " + $p.Name + " " + $p.Side + " 量=" + $p.Size + " 盈亏=" + $p.Upl + " 比例=" + $p.Ratio.ToString('0.00') + "%")
    }

    Write-Output '--- 3. 离屏渲染 ---'
    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $cfgPath = Join-Path $dir 'pnl-config.ini'
        # 自检会临时改写配置文件, 先整份备份, 结束后原样还原(里面是加密后的 Key)
        $cfgBak = $null
        if (Test-Path $cfgPath) { $cfgBak = [System.IO.File]::ReadAllBytes($cfgPath) }
        $cases = @(@('pnl-compact.png', '1', '0'), @('pnl-list.png', '0', '0'), @('pnl-list-glass.png', '0', '1'))
        foreach ($cs in $cases) {
            Set-Content -Path $cfgPath -Value ("compact=" + $cs[1]) -Encoding UTF8
            $f = New-Object OkxPnl.Board $dir
            $f.DebugSetKey()
            if ($cs[2] -eq '1') { $f.DebugGlass($true) }
            $f.DebugInject($ps, 12345.67, 424.5)
            $f.DebugCandles($ps)
            $f.Show(); $f.Hide()
            $w = $f.Width; $h = $f.Height
            $bmp = New-Object System.Drawing.Bitmap $w, $h
            $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $w, $h))
            $bmp.Save((Join-Path $dir $cs[0]), [System.Drawing.Imaging.ImageFormat]::Png)
            $big = New-Object System.Drawing.Bitmap ($w * 3), ($h * 3)
            $gg = [System.Drawing.Graphics]::FromImage($big)
            $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $gg.DrawImage($bmp, 0, 0, $w * 3, $h * 3)
            $gg.Dispose()
            $big.Save((Join-Path $dir ($cs[0].Replace('.png', '-x3.png'))), [System.Drawing.Imaging.ImageFormat]::Png)
            $big.Dispose()
            $bmp.Dispose()
            $f.Close()
            Write-Output ("  " + $cs[0] + " 已生成 " + $w + "x" + $h)
        }
        # 空仓态(极简单行): 有权益但没有持仓, 右侧应显示"空仓"而不是 +0.0
        Set-Content -Path $cfgPath -Value 'compact=1' -Encoding UTF8
        $fe = New-Object OkxPnl.Board $dir
        $fe.DebugSetKey()
        $fe.DebugInject((New-Object 'System.Collections.Generic.List[OkxPnl.Pos]'), 69.78, 0)
        $fe.Show(); $fe.Hide()
        $we = $fe.Width; $he = $fe.Height
        $be = New-Object System.Drawing.Bitmap $we, $he
        $fe.DrawToBitmap($be, (New-Object System.Drawing.Rectangle 0, 0, $we, $he))
        $be.Save((Join-Path $dir 'pnl-empty.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $be3 = New-Object System.Drawing.Bitmap ($we * 3), ($he * 3)
        $g3 = [System.Drawing.Graphics]::FromImage($be3)
        $g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g3.DrawImage($be, 0, 0, $we * 3, $he * 3)
        $g3.Dispose()
        $be3.Save((Join-Path $dir 'pnl-empty-x3.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $be3.Dispose(); $be.Dispose(); $fe.Close()
        Write-Output ("  pnl-empty.png 已生成 " + $we + "x" + $he)

        if ($null -ne $cfgBak) { [System.IO.File]::WriteAllBytes($cfgPath, $cfgBak) }
        else { Remove-Item $cfgPath -ErrorAction SilentlyContinue }
    } catch {
        Write-Output ('  渲染失败: ' + $_.Exception.Message)
    }
    exit 0
}

# ---- 单实例：启动前先把之前那个停掉，避免两个悬浮窗叠在一起 ----
$script:myPid = $PID
$script:myPath = Join-Path $dir 'OkxPnl.ps1'
try {
    $old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $script:myPid -and $_.CommandLine -and $_.CommandLine.Contains($script:myPath) }
    if ($old) {
        foreach ($o in $old) { try { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        # 等它真的退出（最多 2 秒），免得新旧同时画
        for ($i = 0; $i -lt 20; $i++) {
            $still = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $script:myPid -and $_.CommandLine -and $_.CommandLine.Contains($script:myPath) }
            if (-not $still) { break }
            Start-Sleep -Milliseconds 100
        }
    }
} catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$form = New-Object OkxPnl.Board $dir
[System.Windows.Forms.Application]::Run($form)
