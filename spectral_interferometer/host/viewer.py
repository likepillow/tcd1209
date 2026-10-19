"""TCD1209 workbench with file replay and Cypress USB transport.

No host FFT is performed to manufacture a displayed distance. Result curves
come exclusively from RESULT packets. Requires Python with Tk 8.6 and NumPy.
"""
import argparse
import queue
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import numpy as np

from receiver import FileReceiver
from live_receiver import USBReceiver
from protocol import Decoder, export_command, acquisition_command
from acquisition_settings import AcquisitionSettings
from workbench import DisplayState, LocalCalibration, load_text, trend


class Plot(ttk.Frame):
    def __init__(self, master, title, color):
        super().__init__(master)
        self.color = color
        self.title = title
        self.data = (np.array([]), np.array([]), '', '', False)
        self.canvas = tk.Canvas(self, background='#ffffff', highlightthickness=1,
                                highlightbackground='#cbd5e1', height=245)
        self.canvas.pack(fill='both', expand=True)
        self.canvas.bind('<Configure>', lambda event: self.redraw())

    def update_data(self, x, y, xlabel, ylabel, *, integer_x=False):
        self.data = (np.asarray(x), np.asarray(y), xlabel, ylabel, integer_x)
        self.redraw()

    def redraw(self):
        c = self.canvas
        c.delete('all')
        width, height = c.winfo_width(), c.winfo_height()
        if width < 150 or height < 120:
            return
        x, y, xlabel, ylabel, integer_x = self.data
        left, right, top, bottom = 88, width-25, 48, height-49
        c.create_text(16, 17, anchor='w', text=self.title, fill='#172b4d', font=('Microsoft YaHei UI', 11, 'bold'))
        c.create_text(right, 17, anchor='e', text=ylabel, fill='#475569', font=('Microsoft YaHei UI', 9))
        c.create_text((left+right)/2, height-15, text=xlabel, fill='#475569', font=('Microsoft YaHei UI', 9))
        finite = np.isfinite(x) & np.isfinite(y)
        if not finite.any():
            c.create_text(width/2, height/2, text='等待有效数据', fill='#64748b', font=('Microsoft YaHei UI', 12))
            return
        xmin, xmax = float(np.min(x[finite])), float(np.max(x[finite]))
        ymin, ymax = float(np.min(y[finite])), float(np.max(y[finite]))
        if xmin == xmax:
            xmin -= .5
            xmax += .5
        margin = (ymax-ymin)*.07 if ymin != ymax else max(1e-9, abs(ymin)*.05, .05)
        ymin -= margin
        ymax += margin
        for index in range(5):
            fraction = index/4
            py = bottom-(bottom-top)*fraction
            c.create_line(left, py, right, py, fill='#e8edf3')
            c.create_text(left-10, py, anchor='e', text=f'{ymin+(ymax-ymin)*fraction:.5g}', fill='#64748b', font=('Consolas', 9))
        ticks = np.linspace(xmin, xmax, 5)
        if integer_x:
            ticks = np.unique(np.rint(ticks))
            ticks = ticks[(ticks >= xmin) & (ticks <= xmax)]
        for tick in ticks:
            px = left+(right-left)*(tick-xmin)/(xmax-xmin)
            c.create_line(px, top, px, bottom, fill='#e8edf3')
            c.create_text(px, bottom+13, text=f'{int(tick)}' if integer_x else f'{tick:.5g}', fill='#64748b', font=('Consolas', 9))
        points = []

        def draw_segment():
            if len(points) >= 4:
                c.create_line(*points, fill=self.color, width=1.5)
            elif len(points) == 2:
                px, py = points
                c.create_oval(px-2, py-2, px+2, py+2, fill=self.color, outline='')

        for xv, yv, valid in zip(x, y, finite):
            if not valid:
                draw_segment()
                points = []
                continue
            points.extend((left+(xv-xmin)/(xmax-xmin)*(right-left),
                           bottom-(yv-ymin)/(ymax-ymin)*(bottom-top)))
        draw_segment()


class Viewer:
    def __init__(self, root):
        self.root = root
        self.root.title('TCD1209 光谱干涉测距工作台')
        self.root.geometry('1180x900')
        self.root.minsize(960, 760)
        self.display = DisplayState()
        self.calibration = LocalCalibration()
        self.worker = None
        self.last_revision = -1
        self.last_channel = None
        self.closing = False
        self.close_alarm_shown = False
        self.run_pending = False
        self.channel = tk.StringVar(value='S0')
        self.scale = tk.StringVar(value='1.0')
        self.units = tk.StringVar(value='未指定')
        self.export_period = tk.StringVar(value='1')
        self.source_average_count = tk.StringVar(value='128')
        self.source_smooth_width = tk.StringVar(value='31')
        self.replay_speed = tk.StringVar(value='1×')
        self.window_start = tk.StringVar(value='512')
        self.exposure_us = tk.StringVar(value='422.8')
        self.applied_acquisition = None
        self.acquisition_pending = False
        self.save_copy = tk.BooleanVar(value=False)
        self.source_label = tk.StringVar(value='S：未配置')
        self.k_label = tk.StringVar(value='K：未配置')
        self.data_label = tk.StringVar(value='尚无结果包')
        self.frame_label = tk.StringVar(value='光谱帧：—')
        self.status = tk.StringVar()
        style = ttk.Style()
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10))
        style.configure('TFrame', background='#f3f5f8')
        style.configure('TLabel', background='#f3f5f8')
        style.configure('Title.TLabel', font=('Microsoft YaHei UI', 17, 'bold'), foreground='#172b4d')
        style.configure('Status.TLabel', foreground='#334155')
        style.configure('Error.TLabel', foreground='#b91c1c')
        body = ttk.Frame(root, padding=16)
        body.pack(fill='both', expand=True)
        ttk.Label(body, text='光谱干涉测距工作台', style='Title.TLabel').pack(anchor='w')
        ttk.Label(body, text='支持离线回放 / USB 接收（需配套 FPGA 固件） · 距离读取自结果包').pack(anchor='w', pady=(4, 12))
        toolbar = ttk.Frame(body)
        toolbar.pack(fill='x')
        self.open_button = ttk.Button(toolbar, text='打开 SPIF 记录', command=self.open_replay)
        self.open_button.pack(side='left')
        self.usb_button = ttk.Button(toolbar, text='连接 USB', command=self.open_usb)
        self.usb_button.pack(side='left', padx=6)
        self.replay_stop_button = ttk.Button(toolbar, text='停止回放', command=self.stop_replay)
        self.replay_stop_button.pack(side='left', padx=6)
        ttk.Label(toolbar, text='回放速度').pack(side='left', padx=(10, 3))
        speed_box = ttk.Combobox(toolbar, textvariable=self.replay_speed,
                                values=('0.25×', '0.5×', '1×', '2×', '4×', '不限速'),
                                state='readonly', width=7)
        speed_box.pack(side='left')
        speed_box.bind('<<ComboboxSelected>>', self.change_replay_speed)
        self.start_button = ttk.Button(toolbar, text='开始采集', command=self.start_acquisition, state='disabled')
        self.start_button.pack(side='left', padx=(12, 3))
        self.stop_button = ttk.Button(toolbar, text='停止采集', command=self.stop_acquisition, state='disabled')
        self.stop_button.pack(side='left', padx=3)
        self.disconnect_button = ttk.Button(toolbar, text='断开 USB', command=self.disconnect_usb, state='disabled')
        self.disconnect_button.pack(side='left', padx=3)
        ttk.Checkbutton(toolbar, text='保存接收流和距离 CSV', variable=self.save_copy).pack(side='left', padx=8)
        ttk.Button(toolbar, text='导出当前曲线 TXT', command=self.export_curve).pack(side='right')
        cal = ttk.LabelFrame(body, text='本地标定草稿（不会自动应用到 FPGA）', padding=10)
        cal.pack(fill='x', pady=12)
        acquisition_row = ttk.Frame(cal)
        acquisition_row.pack(fill='x', pady=(0, 8))
        ttk.Label(acquisition_row, text='S0 起点 W（0～1024）').pack(side='left')
        ttk.Entry(acquisition_row, textvariable=self.window_start, width=7).pack(side='left', padx=6)
        ttk.Label(acquisition_row, text='曝光周期 T / μs').pack(side='left')
        ttk.Entry(acquisition_row, textvariable=self.exposure_us, width=9).pack(side='left', padx=6)
        ttk.Label(acquisition_row, text='422.8～999.8；步进0.2').pack(side='left')
        self.acquisition_button = ttk.Button(acquisition_row, text='应用 W/T（清除标定）',
                                             command=self.send_acquisition, state='disabled')
        self.acquisition_button.pack(side='right')
        self.acquisition_status = tk.StringVar(value='W/T 尚未经设备确认；需配套新版 FPGA 固件')
        ttk.Label(cal, textvariable=self.acquisition_status).pack(anchor='w')
        first = ttk.Frame(cal)
        first.pack(fill='x')
        ttk.Button(first, text='当前单帧 S0 设为 S（快速）', command=self.capture_source).pack(side='left')
        ttk.Button(first, text='导入 S 文本', command=self.load_source).pack(side='left', padx=6)
        ttk.Button(first, text='保存光源 S', command=self.save_source).pack(side='left', padx=(0, 6))
        ttk.Button(first, text='导入 K 文本', command=self.load_k).pack(side='left')
        ttk.Label(first, text='距离比例').pack(side='left', padx=(16, 5))
        ttk.Entry(first, textvariable=self.scale, width=8).pack(side='left')
        ttk.Label(first, text='K 单位').pack(side='left', padx=(12, 5))
        ttk.Entry(first, textvariable=self.units, width=12).pack(side='left')
        average_row = ttk.Frame(cal)
        average_row.pack(fill='x', pady=(6, 0))
        ttk.Label(average_row, text='参考 S 平均帧数').pack(side='left')
        ttk.Entry(average_row, textvariable=self.source_average_count, width=6).pack(side='left', padx=6)
        ttk.Button(average_row, text='多帧平均设为 S', command=self.capture_source_average).pack(side='left')
        ttk.Button(average_row, text='取消平均', command=self.cancel_source_average).pack(side='left', padx=6)
        ttk.Label(average_row, text='参考S平滑宽度（奇数）').pack(side='left', padx=(10, 3))
        ttk.Entry(average_row, textvariable=self.source_smooth_width, width=5).pack(side='left')
        ttk.Button(average_row, text='平滑参考S（可选）', command=self.smooth_source).pack(side='left', padx=6)
        ttk.Button(average_row, text='恢复原始S', command=self.restore_source).pack(side='left')
        second = ttk.Frame(cal)
        second.pack(fill='x', pady=(8, 6))
        ttk.Button(second, text='保存 S/K 标定', command=self.save_calibration).pack(side='left')
        ttk.Button(second, text='读取标定', command=self.load_calibration).pack(side='left', padx=6)
        ttk.Button(second, text='导出配置包', command=self.export_commands).pack(side='left')
        self.send_button = ttk.Button(second, text='发送 S/K 至 FPGA', command=self.send_configuration, state='disabled')
        self.send_button.pack(side='right')
        export_row = ttk.Frame(cal)
        export_row.pack(fill='x', pady=(0, 6))
        ttk.Label(export_row, text='S0 输出间隔（帧）').pack(side='left')
        ttk.Entry(export_row, textvariable=self.export_period, width=10).pack(side='left', padx=6)
        self.period_button = ttk.Button(export_row, text='应用间隔', command=self.send_period, state='disabled')
        self.period_button.pack(side='right')
        self.command_status = tk.StringVar(value='尚无在线配置确认')
        ttk.Label(cal, textvariable=self.command_status).pack(anchor='w')
        ttk.Label(export_row, text='0：关闭；N：每 N 帧选取一次。在线需点击应用，不改变测距帧率').pack(side='left')
        ttk.Label(cal, textvariable=self.source_label, wraplength=1070).pack(anchor='w')
        ttk.Label(cal, textvariable=self.k_label, wraplength=1070).pack(anchor='w')
        info = ttk.Frame(body)
        info.pack(fill='x', pady=(0, 5))
        ttk.Label(info, text='查看').pack(side='left')
        ttk.Combobox(info, textvariable=self.channel, values=('S0', 'S1', 'S2', 'P1'), state='readonly', width=7).pack(side='left', padx=8)
        ttk.Label(info, textvariable=self.frame_label).pack(side='left')
        ttk.Label(info, text='像素为原始 2048 有效点的零基下标').pack(side='right')
        self.spectrum_plot = Plot(body, 'CCD 光谱 / 相位', '#176b9b')
        self.spectrum_plot.pack(fill='both', expand=True)
        ttk.Label(body, textvariable=self.data_label, wraplength=1100).pack(anchor='w', pady=8)
        self.distance_plot = Plot(body, '距离随时间变化', '#a55020')
        self.distance_plot.pack(fill='both', expand=True)
        self.status_widget = ttk.Label(body, textvariable=self.status, wraplength=1110, style='Status.TLabel')
        # Reserve status space BEFORE expanding canvases; high-DPI windows must
        # never clip the integrity/error message as the last packed widget.
        self.status_widget.pack(side='bottom', fill='x', pady=(8, 0), before=self.spectrum_plot)
        self.root.protocol('WM_DELETE_WINDOW', self.close)
        self.root.after(50, self.refresh)

    def error(self, error):
        messagebox.showerror('操作未完成', str(error), parent=self.root)

    def active(self):
        return self.worker is not None and self.worker.is_alive()

    def start_replay(self, path, record_to=None):
        if self.active():
            raise ValueError('请先停止当前回放，等待工作线程结束')
        self.display.reset()
        self.worker = FileReceiver(path, self.display, record_to=record_to,
                                   speed=self._replay_speed_value())
        self.worker.start()

    def open_replay(self):
        path = filedialog.askopenfilename(parent=self.root, title='打开已保存的 SPIF 字节流', filetypes=[('SPIF 数据', '*.spif'), ('所有文件', '*.*')])
        if not path:
            return
        record_to = None
        if self.save_copy.get():
            record_to = filedialog.asksaveasfilename(parent=self.root, title='新记录目录名称（必须尚不存在）')
            if not record_to:
                return
        try:
            self.start_replay(path, record_to)
        except Exception as error:
            self.error(error)

    def open_usb(self):
        try:
            if self.active():
                raise ValueError('请先停止当前会话')
            dll = filedialog.askopenfilename(parent=self.root, title='选择已安装的 CyUSB.dll', filetypes=[('Cypress 驱动库', 'CyUSB.dll')])
            if not dll:
                return
            record_to = None
            if self.save_copy.get():
                record_to = filedialog.asksaveasfilename(parent=self.root, title='USB 新记录目录名称（必须尚不存在）')
                if not record_to:
                    return
            self.display.reset()
            self.command_status.set('USB 打开中；尚无配置确认')
            self.applied_acquisition = None
            self.acquisition_pending = False
            self.run_pending = False
            self.worker = USBReceiver(dll, self.display, record_to=record_to)
            self.worker.start()
        except Exception as error:
            self.error(error)

    def send_configuration(self):
        try:
            if self.applied_acquisition != AcquisitionSettings(self.calibration.window_start, self.calibration.period_pixels):
                raise ValueError('标定的 W/T 与设备已确认配置不一致，请先应用对应 W/T')
            self.sync_calibration_fields()
            packets = list(Decoder().feed(self.calibration.commands()))
            for packet in packets:
                self.worker.submit(packet)
            self.command_status.set('S/K 已排队；等待 FPGA 分别确认')
        except Exception as error:
            self.error(error)

    def send_acquisition(self):
        try:
            if self.acquisition_pending:
                raise ValueError('上一条 W/T 配置仍在等待确认')
            settings = AcquisitionSettings.from_text(self.window_start.get(), self.exposure_us.get())
            self.worker.submit(acquisition_command(settings, 0))
            self.acquisition_pending = True
            self.applied_acquisition = None
            self.acquisition_status.set('等待 FPGA 排空旧帧并应用 W/T；生效后需重新配置 S/K')
        except Exception as error:
            self.error(error)

    def send_period(self):
        try:
            self.worker.submit(export_command(int(self.export_period.get()), 0))
            self.command_status.set('输出间隔已排队；等待 FPGA 确认')
        except Exception as error:
            self.error(error)

    def _replay_speed_value(self):
        text = self.replay_speed.get()
        return None if text == '不限速' else float(text.rstrip('×'))

    def change_replay_speed(self, _event=None):
        if isinstance(self.worker, FileReceiver) and self.worker.is_alive():
            self.worker.set_speed(self._replay_speed_value())

    def stop_replay(self):
        if isinstance(self.worker, FileReceiver) and self.worker.is_alive():
            self.worker.stop()

    def start_acquisition(self):
        try:
            if not isinstance(self.worker, USBReceiver) or not self.worker.ready.is_set():
                raise ValueError('USB 尚未进入准备状态')
            self.worker.start_acquisition()
            self.run_pending = True
        except Exception as error:
            self.error(error)

    def stop_acquisition(self):
        try:
            if not isinstance(self.worker, USBReceiver) or not self.worker.ready.is_set():
                raise ValueError('USB 尚未进入准备状态')
            self.worker.stop_acquisition()
            self.run_pending = True
        except Exception as error:
            self.error(error)

    def disconnect_usb(self):
        if isinstance(self.worker, USBReceiver) and self.worker.connected.is_set():
            self.worker.request_disconnect()

    def capture_source(self):
        try:
            state = self.display.snapshot()
            if isinstance(self.worker, USBReceiver) and (self.acquisition_pending or state['acquisition'] is None):
                raise ValueError('请先应用 W/T 并等待设备确认及新 S0 帧')
            settings = state.get('acquisition') or AcquisitionSettings()
            if (self.calibration.window_start, self.calibration.period_pixels) != (settings.window_start, settings.period_pixels):
                raise ValueError('本地标定 W/T 与当前光谱不一致，请先应用对应配置')
            if 'S0' not in state['channels']:
                raise ValueError('尚无完整 S0 光谱帧')
            if state['invalid'].get('S0', False):
                raise ValueError('当前 S0 带无效标志，不能用作光源参考')
            self.calibration.set_source(state['channels']['S0'], f'回放 S0，帧号 {state["frames"]["S0"]}')
            self.calibration_labels()
        except Exception as error:
            self.error(error)

    def capture_source_average(self):
        try:
            if not self.active():
                raise ValueError('请先开始 USB 采集或记录回放，再采集未来帧作平均')
            state = self.display.snapshot()
            if isinstance(self.worker, USBReceiver) and (self.acquisition_pending or state['acquisition'] is None):
                raise ValueError('请先应用 W/T 并等待设备确认')
            settings = state.get('acquisition') or AcquisitionSettings()
            if (self.calibration.window_start, self.calibration.period_pixels) != (settings.window_start, settings.period_pixels):
                raise ValueError('本地标定 W/T 与当前采集配置不一致')
            count = int(self.source_average_count.get())
            self.display.begin_source_average(count)
            self.source_label.set(f'S：正在采集未来 {count} 个有效 S0 帧作逐像素平均；饱和/无效帧自动跳过')
        except Exception as error:
            self.error(error)

    def cancel_source_average(self):
        self.display.cancel_source_average()
        self.calibration_labels()

    def smooth_source(self):
        try:
            self.display.cancel_source_average()
            self.calibration.smooth_source(int(self.source_smooth_width.get()))
            self.calibration_labels()
        except Exception as error:
            self.error(error)

    def restore_source(self):
        try:
            self.display.cancel_source_average()
            self.calibration.restore_source()
            self.calibration_labels()
        except Exception as error:
            self.error(error)

    def load_source(self):
        path = filedialog.askopenfilename(parent=self.root, title='导入光源 S：1024 或 2048 点', filetypes=[('数值文本', '*.txt'), ('所有文件', '*.*')])
        if path:
            try:
                self.calibration.set_source(load_text(path), path)
                self.calibration_labels()
            except Exception as error:
                self.error(error)

    def load_k(self):
        path = filedialog.askopenfilename(parent=self.root, title='导入 K：512、1024 或 2048 点，必须严格单调', filetypes=[('数值文本', '*.txt'), ('所有文件', '*.*')])
        if path:
            try:
                self.calibration.set_k(load_text(path), path)
                self.calibration_labels()
            except Exception as error:
                self.error(error)

    def save_source(self):
        try:
            if self.calibration.source is None:
                raise ValueError('请先采集或导入光源 S')
            path = filedialog.asksaveasfilename(parent=self.root, title='保存光源 S（不要求已导入 K）',
                                               defaultextension='.txt', filetypes=[('数值文本', '*.txt')])
            if path:
                np.savetxt(path, self.calibration.source, fmt='%.17g', header='S: 1024 cropped pixels; '+self.calibration.source_origin)
        except Exception as error:
            self.error(error)

    def calibration_labels(self):
        s, k = self.calibration.source, self.calibration.k
        self.source_label.set('S：未配置' if s is None else f'S：1024 点，范围 {s.min():.6g}..{s.max():.6g} ADC；{self.calibration.source_origin}')
        self.k_label.set('K：未配置' if k is None else f'K：{len(k)} 点，{"升序" if k[-1]>k[0] else "降序"}；{self.calibration.k_origin}')

    def sync_calibration_fields(self):
        value = float(self.scale.get())
        if not np.isfinite(value):
            raise ValueError('距离比例必须有限')
        self.calibration.scale = value
        self.calibration.k_units = self.units.get().strip() or '未指定'

    def save_calibration(self):
        try:
            self.sync_calibration_fields()
            self.calibration.build()
            path = filedialog.asksaveasfilename(parent=self.root, title='保存本地 S/K 标定', defaultextension='.npz', filetypes=[('标定', '*.npz')])
            if path:
                self.calibration.save(path)
        except Exception as error:
            self.error(error)

    def load_calibration(self):
        path = filedialog.askopenfilename(parent=self.root, title='读取本地标定', filetypes=[('标定', '*.npz')])
        if path:
            try:
                self.calibration = LocalCalibration.load(path)
                self.window_start.set(str(self.calibration.window_start))
                self.exposure_us.set(str(self.calibration.period_pixels/5))
                self.scale.set(str(self.calibration.scale))
                self.units.set(self.calibration.k_units)
                self.calibration_labels()
            except Exception as error:
                self.error(error)

    def export_commands(self):
        try:
            self.sync_calibration_fields()
            text = self.export_period.get().strip()
            if not text.isascii() or not text.isdecimal():
                raise ValueError('S0 输出间隔必须为 0 至 4294967295 的整数')
            data = self.calibration.commands(export_period=int(text))
            path = filedialog.asksaveasfilename(parent=self.root, title='导出待发送配置包（不代表已应用）', defaultextension='.spif', filetypes=[('SPIF 配置', '*.spif')])
            if path:
                Path(path).write_bytes(data)
        except Exception as error:
            self.error(error)

    def export_curve(self):
        try:
            state = self.display.snapshot()
            channel = self.channel.get()
            values = state['channels'].get(channel)
            if values is None:
                raise ValueError('所选通道尚无数据')
            path = filedialog.asksaveasfilename(parent=self.root, title=f'导出 {channel} 的 1024 点值', defaultextension='.txt', filetypes=[('数值文本', '*.txt')])
            if path:
                settings = state.get('acquisition')
                start = settings.window_start if settings is not None else 512
                np.savetxt(path, values, fmt='%.17g', header=f'{channel}; frame_id={state["frames"][channel]}; effective CCD indices {start}..{start+1023}')
        except Exception as error:
            self.error(error)

    def refresh(self):
        if self.closing:
            if isinstance(self.worker, USBReceiver):
                if self.worker.shutdown_confirmed.is_set() and not self.worker.is_alive():
                    self.root.destroy()
                    return
                if not self.worker.is_alive() and not self.worker.shutdown_confirmed.is_set():
                    self.closing = False
                    if not self.close_alarm_shown:
                        self.close_alarm_shown = True
                        messagebox.showerror('FPGA 停机未确认',
                            '未取得 FPGA 停止 ACK，窗口保持打开。请重新连接后执行停止，或先人工断电。',
                            parent=self.root)
                    self.root.after(50, self.refresh)
                    return
                self.root.after(50, self.refresh)
                return
            if self.active():
                self.root.after(50, self.refresh)
            else:
                self.root.destroy()
            return
        averaged = self.display.take_source_average()
        if averaged is not None:
            try:
                rms = float(np.sqrt(np.mean(averaged['std']**2)))
                origin = (f'{averaged["count"]} 帧逐像素平均，帧号 '
                          f'{averaged["first_frame"]}..{averaged["last_frame"]}，'
                          f'跳过 {averaged["rejected"]} 帧，单帧噪声 RMS {rms:.4g} ADC')
                self.calibration.set_source(averaged['source'], origin)
                self.calibration_labels()
            except Exception as error:
                self.error(error)
        state = self.display.snapshot()
        if state['source_average'] is not None:
            avg = state['source_average']
            self.source_label.set(f'S：多帧平均中 {avg["accepted"]}/{avg["target"]}；已跳过 {avg["rejected"]} 个饱和/无效帧')
        channel = self.channel.get()
        self.open_button.configure(state='disabled' if self.active() else 'normal')
        self.usb_button.configure(state='disabled' if self.active() else 'normal')
        usb = self.worker if isinstance(self.worker, USBReceiver) else None
        live = usb is not None and usb.ready.is_set()
        running = live and usb.run_state is True
        stopped = live and usb.run_state is False
        self.send_button.configure(state='normal' if live else 'disabled')
        self.period_button.configure(state='normal' if live else 'disabled')
        self.acquisition_button.configure(state='normal' if live and not self.acquisition_pending else 'disabled')
        self.start_button.configure(state='normal' if stopped and not self.run_pending else 'disabled')
        self.stop_button.configure(state='normal' if running and not self.run_pending else 'disabled')
        self.disconnect_button.configure(state='normal' if usb is not None and usb.connected.is_set()
                                         and not usb.disconnect_requested.is_set() else 'disabled')
        self.replay_stop_button.configure(state='normal' if isinstance(self.worker, FileReceiver)
                                          and self.worker.is_alive() else 'disabled')
        if not live:
            self.acquisition_pending = False
        if isinstance(self.worker, USBReceiver):
            while True:
                try:
                    event = self.worker.events.get_nowait()
                except queue.Empty:
                    break
                if event[0] == 'sent':
                    self.command_status.set(f'命令 {event[1]} 已写入 USB，等待 FPGA 确认')
                elif event[0] == 'acquisition':
                    settings = event[1]
                    self.applied_acquisition = settings
                    self.acquisition_pending = False
                    if (self.calibration.window_start, self.calibration.period_pixels) != (settings.window_start, settings.period_pixels):
                        self.calibration = LocalCalibration(window_start=settings.window_start,
                                                            period_pixels=settings.period_pixels)
                    self.calibration_labels()
                    self.acquisition_status.set(f'已确认 W={settings.window_start}，T={settings.exposure_us:g} μs；'
                                                f'标称 {settings.nominal_hz:.2f} 帧/秒；请重新配置 S/K')
                elif event[0] == 'run':
                    self.run_pending = False
                    self.command_status.set('FPGA 已开始采集' if event[1] else 'FPGA 已安全停止并排空')
                elif event[0] == 'failure':
                    self.run_pending = False
                    self.command_status.set('红色告警：'+event[1])
                elif event[0] == 'ack':
                    self.command_status.set(f'命令 {event[1]} FPGA 确认状态 {event[2]}；S/K 版本 {event[3]}/{event[4]}')
        state = self.display.snapshot()
        if state['revision'] != self.last_revision or channel != self.last_channel:
            self.last_revision, self.last_channel = state['revision'], channel
            values = state['channels'].get(channel, np.array([]))
            settings = state.get('acquisition')
            start = settings.window_start if settings is not None else 512
            self.spectrum_plot.update_data(np.arange(start, start+len(values)), values, '有效像素下标',
                                           'ADC 计数' if channel == 'S0' else 'rad' if channel == 'P1' else '归一化值', integer_x=True)
            self.frame_label.set(f'{channel} 帧号：{state["frames"].get(channel, "—")}'
                                 + ('（该帧无效，仅供诊断）' if state['invalid'].get(channel, False) else ''))
            x, y, xlabel = trend(state['history'])
            self.distance_plot.update_data(x, y, xlabel, '距离单位由该帧标定定义', integer_x='结果序号' in xlabel)
            result, packet = state['result'], state['result_packet']
            if result is not None:
                value = '无效（不作为有效测距）' if result.invalid else f'{result.distance:.12g}'
                self.data_label.set(f'距离：{value}  |  结果帧 {packet.frame_id}  |  S/K 版本 {packet.source_version}/{packet.k_version}'
                                    f'  |  主峰 {result.peak}，范围 {result.left}..{result.right}'
                                    f'  |  设备丢帧 {result.dropped_frames}，异常帧 {result.malformed_frames}')
            else:
                self.data_label.set('尚无结果包；不会以软件解算代替 FPGA 距离结果')
            self.status.set(f'{state["status"]}  |  包 {state["packet_count"]}，结果 {state["result_count"]}，'
                            f'缺包 {state["missing"]}，重复/倒序 {state["out_of_order"]}'
                            + ('  |  光学告警：'+state['optical_warning'] if state['optical_warning'] else ''))
            self.status_widget.configure(style='Error.TLabel' if state['error'] or state['optical_warning'] else 'Status.TLabel')
        self.root.after(50, self.refresh)

    def close(self):
        if isinstance(self.worker, USBReceiver):
            if self.worker.shutdown_confirmed.is_set() and not self.worker.is_alive():
                self.root.destroy()
                return
            if self.worker.is_alive():
                self.closing = True
                self.worker.request_disconnect()
                return
            if not self.worker.connected.is_set():
                if not self.worker.ever_connected:
                    self.root.destroy()
                    return
                if messagebox.askyesno('FPGA 停机未确认',
                    '当前 USB 会话没有停止 ACK。请先重新连接停机；若已确认整板人工断电，可选择“是”关闭窗口。',
                    parent=self.root):
                    self.root.destroy()
                return
        else:
            self.closing = True
            self.stop_replay()


def main():
    parser = argparse.ArgumentParser(description='TCD1209 光谱/距离工作台，支持 USB 采集与 SPIF 回放')
    parser.add_argument('--replay', type=Path)
    args = parser.parse_args()
    root = tk.Tk()
    viewer = Viewer(root)
    if args.replay is not None:
        root.after(100, lambda: viewer.start_replay(args.replay))
    root.mainloop()


if __name__ == '__main__':
    main()
