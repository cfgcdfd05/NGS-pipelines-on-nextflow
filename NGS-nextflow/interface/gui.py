import os
import sys
import psutil
import subprocess
from pathlib import Path
import re
import math
from PySide6.QtCore import Qt, QProcess, QProcessEnvironment, QTimer, QThread, Signal, QVariantAnimation, QPropertyAnimation, QEasingCurve, QRect
from PySide6.QtGui import QFont, QTextCursor, QIcon, QPainter, QColor, QPixmap
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QLineEdit, QPushButton, QFileDialog, QTextEdit, QGroupBox, 
    QMessageBox, QCheckBox, QSlider, QProgressBar, QTabWidget, QDialog, QStyle, QSizeGrip,
    QGraphicsDropShadowEffect, QGraphicsOpacityEffect, QScrollArea, QFrame,
    QListWidget, QStackedWidget, QListWidgetItem
)
SCRIPT_DIR = Path(__file__).resolve().parent
APP_ROOT = SCRIPT_DIR.parent
RESULTS_DIR = APP_ROOT / "results"
MODERN_QSS = """
QMainWindow {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:1, stop:0 #0F172A, stop:1 #1E1B4B);
}
QWidget {
    background-color: transparent;
    color: rgba(255, 255, 255, 0.9);
    font-family: 'Plus Jakarta Sans', 'Inter', 'Segoe UI', Arial, sans-serif;
    font-size: 14px;
}
QStackedWidget {
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 20px;
    background: rgba(20, 20, 30, 0.4);
}
QListWidget {
    background: transparent;
    border: none;
    outline: none;
}
QListWidget::item {
    background: transparent;
    color: rgba(255, 255, 255, 0.6);
    padding: 12px 24px;
    border-radius: 16px;
    margin-bottom: 4px;
    font-weight: 600;
}
QListWidget::item:selected {
    background: rgba(255, 255, 255, 0.1);
    color: #FFFFFF;
    border: 1px solid rgba(255, 255, 255, 0.15);
}
QListWidget::item:hover:!selected {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.9);
}
QGroupBox {
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 20px;
    margin-top: 24px;
    padding-top: 20px;
    font-weight: 600;
    background: rgba(20, 20, 30, 0.4);
}
QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 20px;
    padding: 0 8px;
    color: rgba(255, 255, 255, 0.95);
    font-size: 18px;
    font-weight: bold;
    background-color: transparent;
}
QLabel {
    background-color: transparent;
}
QLineEdit {
    background-color: rgba(0, 0, 0, 0.3);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 16px;
    padding: 10px 15px;
    color: rgba(255, 255, 255, 0.9);
}
QLineEdit:hover {
    background-color: rgba(0, 0, 0, 0.4);
}
QLineEdit:focus {
    background-color: rgba(0, 0, 0, 0.5);
    border: 2px solid #1856FF;
}
QPushButton {
    background-color: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 16px;
    padding: 10px 16px;
    color: rgba(255, 255, 255, 0.9);
    font-weight: 600;
}
QPushButton:hover {
    background-color: rgba(255, 255, 255, 0.15);
}
QPushButton:pressed {
    background-color: rgba(255, 255, 255, 0.05);
}
QPushButton:disabled {
    background: rgba(255, 255, 255, 0.02);
    color: rgba(255, 255, 255, 0.3);
    border: 1px solid rgba(255, 255, 255, 0.05);
}
QCheckBox {
    background-color: transparent;
    padding: 10px 0;
    font-size: 14px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.8);
}
QCheckBox:hover {
    color: #FFFFFF;
}
QCheckBox::indicator {
    width: 18px;
    height: 18px;
    border: 1px solid rgba(255, 255, 255, 0.3);
    border-radius: 6px;
    background: rgba(0, 0, 0, 0.3);
}
QCheckBox::indicator:checked {
    background: #1856FF;
    border: 1px solid #1856FF;
}
QTextEdit {
    background-color: rgba(0, 0, 0, 0.3);
    color: rgba(255, 255, 255, 0.9);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 20px;
    padding: 15px;
    font-family: 'JetBrains Mono', 'Consolas', monospace;
}
QProgressBar {
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 8px;
    text-align: center;
    background-color: rgba(0, 0, 0, 0.3);
    color: white;
    font-weight: bold;
}
QProgressBar::chunk {
    background-color: #1856FF;
    border-radius: 8px;
}
QSlider::groove:horizontal {
    border: 1px solid rgba(255, 255, 255, 0.15);
    height: 6px;
    background: rgba(0, 0, 0, 0.3);
    border-radius: 3px;
}
QSlider::handle:horizontal {
    background: #1856FF;
    border: 1px solid rgba(255, 255, 255, 0.5);
    width: 14px;
    margin: -4px 0;
    border-radius: 7px;
}
QSlider::handle:horizontal:hover {
    background: #4A7BFF;
}
"""
def get_gpu_info():
    try:
        res = subprocess.run(["nvidia-smi", "--query-gpu=memory.free,memory.total", "--format=csv,noheader,nounits"], capture_output=True, text=True)
        if res.returncode == 0:
            lines = res.stdout.strip().split('\n')
            gpus = []
            for line in lines:
                if not line.strip(): continue
                parts = line.split(',')
                if len(parts) >= 2:
                    gpus.append((int(parts[0].strip()), int(parts[1].strip())))
            return gpus
    except Exception:
        pass
    return []

def get_vram():
    gpus = get_gpu_info()
    if not gpus:
        return None, None, 0
    total_free = sum(g[0] for g in gpus)
    total_mem = sum(g[1] for g in gpus)
    return total_free, total_mem, len(gpus)

def has_valid_gpu():
    gpus = get_gpu_info()
    if not gpus:
        return False, None
    total_mem = sum(g[1] for g in gpus)
    # Check if at least one physical GPU has >= ~12GB VRAM
    has_compatible_card = any(g[1] >= 11500 for g in gpus)
    return has_compatible_card, total_mem
from PySide6.QtGui import QPainter, QColor
class LimitProgressBar(QProgressBar):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.limit_ratio = 1.0
    def setLimitRatio(self, ratio):
        self.limit_ratio = ratio
        self.update()
    def paintEvent(self, event):
        super().paintEvent(event)
        if 0.0 < self.limit_ratio < 1.0:
            painter = QPainter(self)
            x_pos = int(self.width() * self.limit_ratio)
            painter.fillRect(x_pos - 1, 0, 3, self.height(), QColor(255, 0, 0))
class AnimatedButton(QPushButton):
    def __init__(self, text, base_color="rgba(255, 255, 255, 20)", hover_color="rgba(255, 255, 255, 40)", pressed_color="rgba(255, 255, 255, 10)", text_color="rgba(255, 255, 255, 0.9)", border_color="rgba(255, 255, 255, 0.15)"):
        super().__init__(text)
        self.base_color = QColor(*self._parse_rgba(base_color))
        self.hover_color = QColor(*self._parse_rgba(hover_color))
        self.pressed_color = QColor(*self._parse_rgba(pressed_color))
        self.current_color = self.base_color
        
        self.text_color = text_color
        self.border_color = border_color
        
        # Remove drop shadow for glassmorphism as it conflicts with the translucent panel look
        self.setGraphicsEffect(None)
        
        self.anim = QVariantAnimation(self)
        self.anim.setDuration(150)
        self.anim.valueChanged.connect(self._update_color)
        self._update_stylesheet()
    def _parse_rgba(self, rgba_str):
        if rgba_str.startswith("#"):
            return QColor(rgba_str).red(), QColor(rgba_str).green(), QColor(rgba_str).blue(), 255
        import re
        match = re.search(r'rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)', rgba_str)
        if match:
            r, g, b = int(match.group(1)), int(match.group(2)), int(match.group(3))
            a = float(match.group(4)) * 255 if match.group(4) else 255
            return r, g, b, int(a)
        return 255, 255, 255, 255
    def setColors(self, base_color, hover_color, pressed_color):
        self.base_color = QColor(*self._parse_rgba(base_color))
        self.hover_color = QColor(*self._parse_rgba(hover_color))
        self.pressed_color = QColor(*self._parse_rgba(pressed_color))
        self.current_color = self.base_color
        self._update_stylesheet()
    def _update_color(self, color):
        self.current_color = color
        self._update_stylesheet()
    def _update_stylesheet(self):
        bg_rgba = f"rgba({self.current_color.red()}, {self.current_color.green()}, {self.current_color.blue()}, {self.current_color.alpha() / 255.0})"
        self.setStyleSheet(f"""
            QPushButton {{
                background-color: {bg_rgba};
                border: 1px solid {self.border_color};
                border-radius: 16px;
                padding: 10px 16px;
                color: {self.text_color};
                font-weight: 600;
            }}
            QPushButton:hover {{
                color: #FFFFFF;
                border: 1px solid rgba(255, 255, 255, 0.3);
            }}
            QPushButton:disabled {{
                background-color: rgba(255, 255, 255, 0.02);
                color: rgba(255, 255, 255, 0.3);
                border: 1px solid rgba(255, 255, 255, 0.05);
            }}
        """)
    def enterEvent(self, event):
        if self.isEnabled():
            self.anim.stop()
            self.anim.setStartValue(self.current_color)
            self.anim.setEndValue(self.hover_color)
            self.anim.start()
        super().enterEvent(event)
    def leaveEvent(self, event):
        if self.isEnabled():
            self.anim.stop()
            self.anim.setStartValue(self.current_color)
            self.anim.setEndValue(self.base_color)
            self.anim.start()
        super().leaveEvent(event)
    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and self.isEnabled():
            self.anim.stop()
            self.anim.setStartValue(self.current_color)
            self.anim.setEndValue(self.pressed_color)
            self.anim.start()
        super().mousePressEvent(event)
    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton and self.isEnabled():
            self.anim.stop()
            self.anim.setStartValue(self.current_color)
            if self.underMouse():
                self.anim.setEndValue(self.hover_color)
            else:
                self.anim.setEndValue(self.base_color)
            self.anim.start()
        super().mouseReleaseEvent(event)
class DockerMonitorThread(QThread):
    stats_updated = Signal(float, float)
    def __init__(self):
        super().__init__()
        self.running = True
    def run(self):
        import time, subprocess
        while self.running:
            doc_cpu = 0.0
            doc_mem = 0.0
            try:
                res = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.CPUPerc}},{{.MemUsage}}"], capture_output=True, text=True)
                if res.returncode == 0:
                    lines = res.stdout.strip().split('\n')
                    for line in lines:
                        if not line: continue
                        parts = line.split(',')
                        if len(parts) == 2:
                            cpu_str = parts[0].replace('%', '').strip()
                            try: doc_cpu += float(cpu_str)
                            except: pass
                            
                            mem_str = parts[1].split('/')[0].strip()
                            val = 0.0
                            if 'GiB' in mem_str or 'GB' in mem_str: val = float(mem_str.replace('GiB', '').replace('GB', '').strip())
                            elif 'MiB' in mem_str or 'MB' in mem_str: val = float(mem_str.replace('MiB', '').replace('MB', '').strip()) / 1024.0
                            elif 'KiB' in mem_str or 'KB' in mem_str: val = float(mem_str.replace('KiB', '').replace('KB', '').strip()) / (1024.0 * 1024.0)
                            elif 'B' in mem_str: val = float(mem_str.replace('B', '').strip()) / (1024.0 * 1024.0 * 1024.0)
                            doc_mem += val
            except: pass
            
            self.stats_updated.emit(doc_cpu, doc_mem)
            time.sleep(1.5)
    def stop(self):
        self.running = False
        self.wait()
class ResourceMonitor(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.sys_cpus = psutil.cpu_count(logical=True) or 4
        self.sys_mem_gb = int(psutil.virtual_memory().available / (1024**3))
        if self.sys_mem_gb < 2: self.sys_mem_gb = 2
        
        self.parent_gui = parent
        self.setup_ui()
        
        self.doc_cpu = 0.0
        self.doc_mem = 0.0
        
        self.docker_thread = DockerMonitorThread()
        self.docker_thread.stats_updated.connect(self.update_docker_stats)
        self.docker_thread.start()
        
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update_monitor)
        self.timer.start(1000)
    def update_docker_stats(self, cpu, mem):
        self.doc_cpu = cpu
        self.doc_mem = mem
    def setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setSpacing(15)
        
        monitor_group = QGroupBox("Live Pipeline Usage (via Docker)")
        m_layout = QVBoxLayout()
        self.cpu_bar = LimitProgressBar()
        self.cpu_bar.setFormat("Pipeline CPU: %p%")
        self.mem_bar = LimitProgressBar()
        self.mem_bar.setFormat("Pipeline RAM: %p%")
        self.vram_bar = LimitProgressBar()
        self.vram_bar.setFormat("VRAM Usage: %p%")
        m_layout.addWidget(self.cpu_bar)
        m_layout.addWidget(self.mem_bar)
        m_layout.addWidget(self.vram_bar)
        monitor_group.setLayout(m_layout)
        layout.addWidget(monitor_group)
        alloc_group = QGroupBox("Pipeline Resource Allocation")
        a_layout = QVBoxLayout()
        
        self.lbl_cpu = QLabel(f"Max CPU Cores: {self.parent_gui.alloc_cpus} / {self.sys_cpus}")
        self.slider_cpu = QSlider(Qt.Horizontal)
        self.slider_cpu.setMinimum(1)
        self.slider_cpu.setMaximum(self.sys_cpus)
        self.slider_cpu.setValue(self.parent_gui.alloc_cpus)
        self.slider_cpu.valueChanged.connect(self.update_cpu)
        a_layout.addWidget(self.lbl_cpu)
        a_layout.addWidget(self.slider_cpu)
        
        self.lbl_mem = QLabel(f"Max Memory (GB): {self.parent_gui.alloc_mem} / {self.sys_mem_gb}")
        self.slider_mem = QSlider(Qt.Horizontal)
        self.slider_mem.setMinimum(2)
        self.slider_mem.setMaximum(self.sys_mem_gb)
        self.slider_mem.setValue(self.parent_gui.alloc_mem)
        self.slider_mem.valueChanged.connect(self.update_mem)
        a_layout.addWidget(self.lbl_mem)
        a_layout.addWidget(self.slider_mem)
        
        alloc_group.setLayout(a_layout)
        layout.addWidget(alloc_group)
        layout.addStretch()
    def update_cpu(self, val):
        self.parent_gui.alloc_cpus = val
        self.lbl_cpu.setText(f"Max CPU Cores: {val} / {self.sys_cpus}")
    def update_mem(self, val):
        self.parent_gui.alloc_mem = val
        self.lbl_mem.setText(f"Max Memory (GB): {val} / {self.sys_mem_gb}")
    def update_monitor(self):
        cpu_sys_max = self.sys_cpus * 100
        cpu_alloc_max = self.parent_gui.alloc_cpus * 100
        cpu_used = min(self.doc_cpu, cpu_sys_max)
        cpu_percent = (cpu_used / cpu_sys_max) * 100 if cpu_sys_max > 0 else 0
        
        self.cpu_bar.setValue(int(cpu_percent))
        self.cpu_bar.setFormat(f"Pipeline CPU: {int(self.doc_cpu)}% / {cpu_alloc_max}% (Limit)")
        self.cpu_bar.setLimitRatio(self.parent_gui.alloc_cpus / self.sys_cpus)
        
        mem_sys_max = self.sys_mem_gb
        mem_alloc_max = self.parent_gui.alloc_mem
        mem_used = min(self.doc_mem, mem_sys_max)
        mem_percent = (mem_used / mem_sys_max) * 100 if mem_sys_max > 0 else 0
        
        self.mem_bar.setValue(int(mem_percent))
        self.mem_bar.setFormat(f"Pipeline RAM: {self.doc_mem:.1f} GB / {mem_alloc_max:.1f} GB (Limit)")
        self.mem_bar.setLimitRatio(self.parent_gui.alloc_mem / self.sys_mem_gb)
        
        # Color coding: Green if under 60% of alloc, Yellow if 60-85%, Red if over 85%
        cpu_alloc_percent = (self.doc_cpu / cpu_alloc_max) * 100 if cpu_alloc_max > 0 else 0
        mem_alloc_percent = (self.doc_mem / mem_alloc_max) * 100 if mem_alloc_max > 0 else 0
        
        cpu_color = "#dc3545" if cpu_alloc_percent > 85 else ("#d39e00" if cpu_alloc_percent > 60 else "#28a745")
        mem_color = "#dc3545" if mem_alloc_percent > 85 else ("#d39e00" if mem_alloc_percent > 60 else "#28a745")
        
        self.cpu_bar.setStyleSheet(f"QProgressBar::chunk {{ background-color: {cpu_color}; border-radius: 5px; }}")
        self.mem_bar.setStyleSheet(f"QProgressBar::chunk {{ background-color: {mem_color}; border-radius: 5px; }}")
        
        vram_free, vram_total, num_gpus = get_vram()
        if vram_free is not None and vram_total is not None and vram_total > 0:
            gpu_label = f" ({num_gpus} GPUs)" if num_gpus > 1 else ""
            if vram_total < 11500:
                self.vram_bar.setFormat(f"VRAM{gpu_label}: {(vram_total/1024):.1f} GB (<12GB: GPU Disabled)")
                self.vram_bar.setValue(0)
                self.vram_bar.setStyleSheet("QProgressBar::chunk { background-color: #808080; border-radius: 5px; }")
            else:
                vram_used = vram_total - vram_free
                vram_percent = (vram_used / vram_total) * 100
                self.vram_bar.setValue(int(vram_percent))
                self.vram_bar.setFormat(f"VRAM Usage{gpu_label}: {(vram_used/1024):.1f} GB / {(vram_total/1024):.1f} GB")
                vram_color = "#dc3545" if vram_percent > 85 else ("#d39e00" if vram_percent > 60 else "#28a745")
                self.vram_bar.setStyleSheet(f"QProgressBar::chunk {{ background-color: {vram_color}; border-radius: 5px; }}")
        else:
            self.vram_bar.setFormat("VRAM Not Detected (GPU Disabled)")
            self.vram_bar.setValue(0)
PIPELINE_STEPS = {
    "Germline GPU": ["FastQC", "fastp", "fq2bam", "HaplotypeCaller", "JointGenotyping", "Filtration"],
    "Germline CPU": ["FastQC", "fastp", "BWA mem", "MarkDuplicates", "HaplotypeCaller", "CombineGVCFs", "JointGenotyping", "Filtration"],
    "RNA-seq CPU": ["FastQC", "fastp", "STAR", "featureCounts"],
    "RNA-seq GPU": ["FastQC", "fastp", "Parabricks rna_fq2bam", "featureCounts"],
    "ChIP-seq GPU": ["FastQC", "fastp", "fq2bam", "MACS2"],
    "ChIP-seq CPU": ["FastQC", "fastp", "BWA mem", "MarkDuplicates", "MACS2"],
    "Somatic GPU": ["FastQC", "fastp", "fq2bam", "Mutect2", "FilterMutectCalls", "PASS VCF"],
    "Somatic CPU": ["FastQC", "fastp", "BWA mem", "MarkDuplicates", "Mutect2", "FilterMutectCalls", "PASS VCF"],
    "scRNA-seq": ["FastQC", "STARsolo", "Summary"]
}
TOOL_DESCRIPTIONS = {
    "FastQC": "FastQC is a quality control application used to analyze high-throughput sequence data. It reads raw sequencing files (FASTQ) and performs a series of analytical modules to check for potential problems such as low-confidence base calls, sequence biases, adapter contamination, and overrepresented sequences. Generating a comprehensive HTML report, FastQC allows researchers to quickly evaluate whether their data is of high enough quality to proceed with downstream mapping and assembly tasks. It is considered the industry standard first-step for any next-generation sequencing bioinformatics pipeline, ensuring that all subsequent variant calling or peak detection is built on fundamentally sound and unbiased data.",
    "fastp": "fastp is an ultra-fast, all-in-one preprocessor for FASTQ files that performs essential data cleaning before alignment. It automatically detects and trims sequencing adapters, filters out reads with poor quality scores, and trims low-quality bases from the ends of reads. Because it is written in C++ and heavily multi-threaded, it completes these tasks significantly faster than traditional tools like Trimmomatic. Additionally, it generates highly visual HTML and JSON reports that detail the read quality before and after filtering. By cleaning the raw reads, fastp significantly improves the accuracy and efficiency of downstream genomic alignments.",
    "fq2bam": "fq2bam is an NVIDIA Parabricks GPU-accelerated tool that drastically speeds up the read alignment process. It acts as a hyper-optimized equivalent to the traditional BWA-MEM aligner, mapping raw paired-end DNA sequencing reads (FASTQ) against a large reference genome. Not only does it perform the initial alignment, but it also simultaneously sorts the resulting BAM file and marks PCR duplicates in a single pass. By leveraging the parallel computing power of NVIDIA GPUs, fq2bam can reduce what normally takes several hours on a CPU down to just a few minutes, massively accelerating the variant calling pipeline.",
    "BWA mem": "BWA-MEM (Burrows-Wheeler Aligner) is an industry-standard software algorithm used for mapping low-divergent DNA sequence reads against a large reference genome, such as the human genome. It is highly accurate and performs exceptionally well with reads generated by Illumina sequencing machines. BWA-MEM employs a seeding-and-extension approach to efficiently locate the best mapping positions for each read, accommodating mismatches and small gaps caused by genetic variants or sequencing errors. The output is a SAM file that provides the foundation for all subsequent analyses, making BWA-MEM a critical, highly-trusted component of modern bioinformatics and genomic research.",
    "MarkDuplicates": "The GATK MarkDuplicates tool is designed to locate and tag duplicate reads within a BAM or SAM file. During the library preparation phase of sequencing, DNA fragments are often amplified using PCR, which can create identical copies of the exact same DNA molecule. If left unchecked, these artificial duplicates will heavily bias downstream variant calling by falsely inflating the confidence of specific mutations. MarkDuplicates analyzes the start and end coordinates of aligned reads to identify these clones, tagging them so that downstream algorithms like HaplotypeCaller can ignore them, ensuring that variant calls are based strictly on unique biological evidence.",
    "DeepVariant": "DeepVariant is a highly advanced, deep learning-based variant caller developed by Google and accelerated by NVIDIA Parabricks. Instead of relying strictly on traditional statistical models, DeepVariant converts aligned genomic reads (BAM files) into visual image tensors and uses a Convolutional Neural Network (CNN) to identify genetic variants (SNPs and indels). This image-recognition approach allows it to accurately distinguish between true biological mutations and sequencing artifacts, often outperforming traditional callers in complex genomic regions. By utilizing GPUs, the Parabricks implementation of DeepVariant delivers these highly accurate genomic variant calls at unprecedented, industry-leading speeds.",
    "HaplotypeCaller": "HaplotypeCaller is the flagship variant calling tool within the GATK (Genome Analysis Toolkit) suite, widely considered the gold standard for identifying germline SNPs and indels. Rather than simply looking at piled-up reads, it dynamically identifies regions of the genome that show signs of variation and performs a complete local re-assembly of the DNA sequence (haplotypes) in those active regions. This sophisticated re-assembly process allows it to accurately call complex genetic insertions and deletions that simpler algorithms often miss. It outputs its findings into a Genomic VCF (GVCF) file, setting the stage for highly accurate joint cohort genotyping.",
    "CombineGVCFs": "CombineGVCFs is a crucial utility in the GATK suite used for scaling variant discovery across large cohorts of patients or samples. When analyzing multiple samples, it is highly computationally inefficient to analyze them all at once initially. Instead, researchers run HaplotypeCaller on each sample individually to generate a single-sample GVCF. CombineGVCFs then merges these individual GVCF files into a single, massive multi-sample GVCF file. This consolidated file perfectly aligns the genomic data of all patients, allowing the subsequent Joint Genotyping step to accurately compare variant frequencies and evaluate statistical confidence across the entire population simultaneously.",
    "JointGenotyping": "Joint Genotyping (GenotypeGVCFs) is the final variant discovery step in the GATK Best Practices pipeline. Rather than analyzing each sample in isolation, this tool analyzes a merged cohort GVCF file, leveraging the statistical power of the entire group of samples simultaneously. If a specific mutation is weakly supported in one patient but strongly supported in ten others, joint genotyping uses the population data to confidently validate the weak call. This group-aware approach significantly reduces false positives, improves the accuracy of rare variant detection, and ensures that every patient has a definitive genotype call at every mutated site across the genome.",
    "Filtration": "Variant Filtration is the process of applying hard statistical thresholds to raw variant calls (VCFs) to separate true biological mutations from sequencing artifacts. Even the best variant callers produce false positives due to machine errors, repetitive DNA regions, or strand biases. This step filters out untrustworthy variants by evaluating metrics such as Quality by Depth (QD), Mapping Quality (MQ), and Fisher Strand bias (FS). Variants failing these strict thresholds are tagged in the VCF file so they can be ignored in downstream clinical or research analyses. This ensures the final dataset is of the highest possible diagnostic quality.",
    "MACS2": "MACS2 (Model-based Analysis of ChIP-Seq) is the industry-leading algorithm for identifying transcription factor binding sites and histone modification peaks in ChIP-seq datasets. It works by analyzing the distribution of aligned reads across the genome to detect regions where proteins are significantly enriched compared to a background control sample. MACS2 dynamically models the shift size of the sequenced DNA fragments to pinpoint the exact binding locations of regulatory proteins with high statistical confidence. The resulting 'peaks' allow researchers to understand epigenetic gene regulation, map open chromatin regions, and identify crucial DNA-protein interaction networks within the cell.",
    "STAR": "STAR (Spliced Transcripts Alignment to a Reference) is an ultra-fast, RNA-seq aligner that maps RNA reads directly to the genome while seamlessly handling large intronic gaps. It is highly optimized for performance and is the gold standard for discovering novel splice junctions and quantifying gene expression.",
    "featureCounts": "featureCounts is a highly efficient read quantification program that assigns mapped sequencing reads to genomic features (like genes or exons). It is an essential downstream step in RNA-seq that translates aligned BAM files into a simple matrix of gene expression counts for differential expression analysis.",
    "Parabricks rna_fq2bam": "NVIDIA Clara Parabricks rna_fq2bam accelerates STAR RNA-seq alignment using GPUs. It provides blisteringly fast mapping to the genome while seamlessly handling large intronic gaps, drastically reducing pipeline execution time on hardware with NVIDIA GPUs.",
    "Mutect2": "GATK Mutect2 is the gold-standard somatic variant caller designed to detect mutations in cancer genomes. Unlike HaplotypeCaller (which assumes germline diploid genetics), Mutect2 is specifically built to identify low-frequency somatic mutations present in only a fraction of tumor cells. It uses a sophisticated Bayesian model to distinguish true somatic variants from sequencing artifacts and germline polymorphisms, even at very low allele fractions (<1%). Mutect2 can operate in tumor-only mode (without a matched normal) or in tumor-normal paired mode for maximum specificity.",
    "FilterMutectCalls": "FilterMutectCalls is a GATK post-processing tool that applies a series of sophisticated statistical filters to raw Mutect2 somatic variant calls. It evaluates each candidate mutation against multiple quality metrics including strand bias, mapping quality, contamination estimates, and orientation bias artifacts. Variants failing these filters are tagged in the VCF FILTER column, allowing downstream analyses to focus exclusively on high-confidence somatic mutations. This step is critical for reducing false positive rates in cancer genomics studies.",
    "PASS VCF": "The PASS VCF extraction step uses bcftools to select only those somatic variant calls that have passed all quality filters applied by FilterMutectCalls. This produces a clean, publication-ready VCF file containing only high-confidence somatic mutations suitable for downstream analyses such as mutational signature profiling, driver gene identification, and clinical reporting.",
    "STARsolo": "STARsolo is a built-in module of the STAR aligner specifically designed for processing single-cell RNA-seq data from 10x Genomics Chromium platforms. It performs simultaneous genome alignment, cell barcode demultiplexing, and UMI (Unique Molecular Identifier) counting in a single pass. STARsolo generates gene expression count matrices compatible with downstream analysis tools like Seurat and Scanpy. It is extremely fast and memory-efficient compared to CellRanger, while producing nearly identical results.",
    "Summary": "The Summary process parses STARsolo output matrices to generate key single-cell quality metrics including: estimated number of cells, total features (genes) detected, total UMI counts, and mean UMIs per cell. These metrics provide a quick quality assessment of the single-cell library before deeper analysis with tools like Seurat or Scanpy."
}
from PySide6.QtWidgets import QGraphicsBlurEffect
from PySide6.QtCore import QPoint
class HorizontalScrollArea(QScrollArea):
    def wheelEvent(self, event):
        delta = event.angleDelta().y()
        # Convert vertical wheel scrolling to horizontal scroll
        self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - delta)
class FlowchartViewer(QFrame):
    def __init__(self, pipeline_type, parent=None):
        super().__init__(parent)
        self.pipeline_type = pipeline_type
        self.steps = PIPELINE_STEPS.get(pipeline_type, [])
        self.parent_gui = parent
        
        self.setObjectName("FlowchartViewer")
        self.setStyleSheet("""
            #FlowchartViewer {
                background-color: rgba(0, 0, 0, 128);
                border-radius: 20px;
            }
        """)
        
        if parent:
            self.resize(parent.size())
            self.move(0, 0)
            
            # Heavy background blur on the central widget behind the overlay
            if hasattr(self.parent_gui, 'centralWidget'):
                self.bg_blur = QGraphicsBlurEffect()
                self.bg_blur.setBlurRadius(25)
                self.parent_gui.centralWidget().setGraphicsEffect(self.bg_blur)
            
        self.main_layout = QVBoxLayout(self)
        self.main_layout.setContentsMargins(40, 40, 40, 40)
        
        # Header
        header_layout = QHBoxLayout()
        title = QLabel(f"{pipeline_type} Flowchart")
        title.setStyleSheet("font-size: 24px; font-weight: bold; color: #F5EDE0; background: transparent;")
        
        self.btn_close = AnimatedButton("Close Flowchart", "rgba(234, 33, 67, 0.2)", "rgba(234, 33, 67, 0.4)", "rgba(234, 33, 67, 0.1)", "rgba(255, 255, 255, 0.9)", "rgba(234, 33, 67, 0.5)")
        self.btn_close.clicked.connect(self.close_animated)
        
        header_layout.addWidget(title)
        header_layout.addStretch()
        header_layout.addWidget(self.btn_close)
        self.main_layout.addLayout(header_layout)
        
        # Split layout for navigation and content
        self.split_layout = QHBoxLayout()
        self.split_layout.setSpacing(40)
        
        # --- LEFT PANEL: Flowchart Navigation ---
        self.scroll = QScrollArea()
        self.scroll.setFixedWidth(260)
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        self.scroll.setStyleSheet("""
            QScrollArea { background: transparent; border: none; } 
            QWidget#canvas_container { background: transparent; }
            QScrollBar:vertical {
                border: 1px solid rgba(255, 255, 255, 0.15);
                background: rgba(0, 0, 0, 0.3);
                width: 10px;
                border-radius: 5px;
            }
            QScrollBar::handle:vertical {
                background: rgba(255, 255, 255, 0.5);
                border-radius: 5px;
            }
        """)
        
        self.canvas = QWidget()
        self.canvas.setObjectName("canvas_container")
        self.canvas_layout = QVBoxLayout(self.canvas)
        self.canvas_layout.setAlignment(Qt.AlignTop | Qt.AlignHCenter)
        self.canvas_layout.setSpacing(15)
        self.canvas_layout.setContentsMargins(10, 10, 10, 10)
        
        for step in self.steps:
            btn = QPushButton(step)
            btn.setFixedSize(200, 80)
            btn.setStyleSheet("""
                QPushButton {
                    background-color: rgba(255, 255, 255, 0.08);
                    color: rgba(255, 255, 255, 0.9);
                    border: 1px solid rgba(255, 255, 255, 0.15);
                    border-radius: 20px;
                    font-weight: 600;
                    font-size: 15px;
                }
                QPushButton:hover {
                    background-color: rgba(255, 255, 255, 0.15);
                    color: #FFFFFF;
                }
            """)
            btn.clicked.connect(lambda checked, s=step: self.show_description(s))
            self.canvas_layout.addWidget(btn)
            
            if step != self.steps[-1]:
                arrow = QLabel("⬇")
                arrow.setAlignment(Qt.AlignCenter)
                arrow.setStyleSheet("color: rgba(255, 255, 255, 0.5); font-size: 28px; font-weight: bold; background: transparent;")
                self.canvas_layout.addWidget(arrow)
                
        self.scroll.setWidget(self.canvas)
        self.split_layout.addWidget(self.scroll)
        
        # --- RIGHT PANEL: Details View (Fixed Container) ---
        self.details_container = QWidget()
        # The details_container will hold the view_details absolutely positioned inside it
        self.split_layout.addWidget(self.details_container)
        
        self.main_layout.addLayout(self.split_layout)
        
        # Build the actual detail card (parented to details_container, but no layout so we can animate geometry)
        self.view_details = QFrame(self.details_container)
        self.view_details.hide() # Hidden by default
        self.view_details.setStyleSheet("""
            QFrame {
                background-color: rgba(20, 20, 30, 0.6);
                border: 1px solid rgba(255, 255, 255, 0.15);
                border-radius: 20px;
            }
        """)
        
        # We need an opacity effect to animate opacity of the detail card
        self.opacity_effect = QGraphicsOpacityEffect(self.view_details)
        self.view_details.setGraphicsEffect(self.opacity_effect)
        
        details_layout = QVBoxLayout(self.view_details)
        details_layout.setContentsMargins(60, 60, 60, 60)
        
        self.detail_title = QLabel("")
        self.detail_title.setStyleSheet("font-size: 36px; font-weight: bold; color: #FFFFFF; border: none; background: transparent;")
        
        self.detail_desc = QLabel("")
        self.detail_desc.setWordWrap(True)
        self.detail_desc.setStyleSheet("font-size: 20px; color: rgba(255, 255, 255, 0.8); line-height: 1.8; border: none; background: transparent;")
        
        details_layout.addWidget(self.detail_title)
        details_layout.addSpacing(30)
        details_layout.addWidget(self.detail_desc)
        details_layout.addStretch()
        
        # Initial fade in of the entire window
        self.setWindowOpacity(0.0)
        self.anim = QPropertyAnimation(self, b"windowOpacity")
        self.anim.setDuration(400)
        self.anim.setStartValue(0.0)
        self.anim.setEndValue(1.0)
        self.anim.setEasingCurve(QEasingCurve.InOutQuad)
        self.anim.start()
    def show_description(self, step):
        self.detail_title.setText(step)
        self.detail_desc.setText(TOOL_DESCRIPTIONS.get(step, "Description not available."))
        
        self.view_details.show()
        
        # Ensure it has the full size of its container to prevent text squishing
        target_rect = self.details_container.rect()
        self.view_details.resize(target_rect.size())
        
        # Start positioned slightly lower for a slide-up effect
        start_pos = target_rect.topLeft()
        start_pos.setY(start_pos.y() + 40)
        end_pos = target_rect.topLeft()
        
        self.pos_anim = QPropertyAnimation(self.view_details, b"pos")
        self.pos_anim.setDuration(400)
        self.pos_anim.setStartValue(start_pos)
        self.pos_anim.setEndValue(end_pos)
        self.pos_anim.setEasingCurve(QEasingCurve.OutCubic)
        
        self.opac_anim = QPropertyAnimation(self.opacity_effect, b"opacity")
        self.opac_anim.setDuration(400)
        self.opac_anim.setStartValue(0.0)
        self.opac_anim.setEndValue(1.0)
        self.opac_anim.setEasingCurve(QEasingCurve.InOutQuad)
        
        self.pos_anim.start()
        self.opac_anim.start()
    def resizeEvent(self, event):
        super().resizeEvent(event)
        if self.view_details.isVisible():
            self.view_details.setGeometry(self.details_container.rect())
            
    def close_animated(self):
        self.anim = QPropertyAnimation(self, b"windowOpacity")
        self.anim.setDuration(300)
        self.anim.setStartValue(1.0)
        self.anim.setEndValue(0.0)
        self.anim.setEasingCurve(QEasingCurve.InOutQuad)
        self.anim.finished.connect(self._finalize_close)
        self.anim.start()
        
    def _finalize_close(self):
        if self.parent_gui and hasattr(self.parent_gui, 'centralWidget'):
            self.parent_gui.centralWidget().setGraphicsEffect(None)
        self.deleteLater()
class PipelineTab(QWidget):
    def __init__(self, pipeline_type, parent=None):
        super().__init__(parent)
        self.pipeline_type = pipeline_type
        self.parent_gui = parent
        self.setup_ui()
    def setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setSpacing(15)
        layout.setContentsMargins(20, 20, 20, 20)
        input_group = QGroupBox("Configuration")
        i_layout = QGridLayout()
        i_layout.setSpacing(10)
        i_layout.setColumnStretch(1, 1)
        name_label = QLabel("Project Name:" if "ChIP" in self.pipeline_type else "Cohort Name:")
        self.input_name = QLineEdit()
        self.input_name.setPlaceholderText("e.g. project_01")
        i_layout.addWidget(name_label, 0, 0)
        i_layout.addWidget(self.input_name, 0, 1, 1, 2)
        ref_name_label = QLabel("Reference Base Name:")
        self.input_ref_name = QLineEdit("hg38")
        self.input_ref_name.setPlaceholderText("e.g. hg38 (no .fasta)")
        i_layout.addWidget(ref_name_label, 1, 0)
        i_layout.addWidget(self.input_ref_name, 1, 1, 1, 2)
        ref_dir_label = QLabel("Reference Folder:")
        self.input_ref_dir = QLineEdit()
        self.input_ref_dir.setPlaceholderText("Folder with reference fasta and indexes")
        self.btn_browse_ref = AnimatedButton("Browse...")
        self.btn_browse_ref.clicked.connect(self.browse_ref)
        i_layout.addWidget(ref_dir_label, 2, 0)
        i_layout.addWidget(self.input_ref_dir, 2, 1)
        i_layout.addWidget(self.btn_browse_ref, 2, 2)
        current_row = 3
        if "Germline" in self.pipeline_type or "ChIP" in self.pipeline_type or "Somatic" in self.pipeline_type:
            self.check_prebuilt = QCheckBox("Pre-built BWA/GATK indexes available in Reference Folder")
            self.check_prebuilt.setChecked(True)
            self.check_prebuilt.stateChanged.connect(self.toggle_build_btn)
            i_layout.addWidget(self.check_prebuilt, current_row, 1, 1, 2)
            current_row += 1
        elif "RNA-seq" in self.pipeline_type or "scRNA-seq" in self.pipeline_type:
            self.check_prebuilt = QCheckBox("Pre-built STAR index available in Reference Folder (star_index/)")
            self.check_prebuilt.setChecked(True)
            self.check_prebuilt.stateChanged.connect(self.toggle_build_btn)
            i_layout.addWidget(self.check_prebuilt, current_row, 1, 1, 2)
            current_row += 1
        if "RNA-seq" in self.pipeline_type or "scRNA-seq" in self.pipeline_type:
            gtf_label = QLabel("Annotation (GTF):")
            self.input_gtf = QLineEdit()
            self.input_gtf.setPlaceholderText("Path to .gtf file (Optional if in ref dir)")
            self.btn_browse_gtf = AnimatedButton("Browse...")
            self.btn_browse_gtf.clicked.connect(self.browse_gtf)
            i_layout.addWidget(gtf_label, current_row, 0)
            i_layout.addWidget(self.input_gtf, current_row, 1)
            i_layout.addWidget(self.btn_browse_gtf, current_row, 2)
            current_row += 1
        fastq_dir_label = QLabel("FASTQ Folder:")
        self.input_fastq_dir = QLineEdit()
        self.input_fastq_dir.setPlaceholderText("Folder with *_R1.fastq.gz and *_R2.fastq.gz")
        self.btn_browse_fastq = AnimatedButton("Browse...")
        self.btn_browse_fastq.clicked.connect(self.browse_fastq)
        i_layout.addWidget(fastq_dir_label, current_row, 0)
        i_layout.addWidget(self.input_fastq_dir, current_row, 1)
        i_layout.addWidget(self.btn_browse_fastq, current_row, 2)
        current_row += 1
        if "ChIP" in self.pipeline_type:
            sample_label = QLabel("Samplesheet (Optional):")
            self.input_sample = QLineEdit()
            self.input_sample.setPlaceholderText("Path to samplesheet.csv (for controls)")
            self.btn_browse_sample = AnimatedButton("Browse...")
            self.btn_browse_sample.clicked.connect(self.browse_sample)
            i_layout.addWidget(sample_label, current_row, 0)
            i_layout.addWidget(self.input_sample, current_row, 1)
            i_layout.addWidget(self.btn_browse_sample, current_row, 2)
            current_row += 1
        if self.pipeline_type != "scRNA-seq":
            self.check_gpu = QCheckBox("Use GPU Acceleration (NVIDIA Parabricks)")
            self.check_low_mem = QCheckBox("Low Memory Mode (<24GB VRAM)")
            
            is_gpu_valid, total_vram = has_valid_gpu()
            if is_gpu_valid:
                self.check_gpu.setChecked(True)
                self.check_gpu.setEnabled(True)
                if total_vram and total_vram < 24000:
                    self.check_low_mem.setChecked(True)
            else:
                self.check_gpu.setChecked(False)
                self.check_gpu.setEnabled(False)
                if total_vram is not None:
                    self.check_gpu.setText(f"Use GPU Acceleration (Disabled: VRAM {total_vram/1024:.1f}GB < 12GB)")
                else:
                    self.check_gpu.setText("Use GPU Acceleration (Disabled: No compatible NVIDIA GPU)")
            
            self.check_gpu.stateChanged.connect(self.on_gpu_toggled)
            self.on_gpu_toggled(self.check_gpu.checkState())
            
            i_layout.addWidget(self.check_gpu, current_row, 1, 1, 2)
            current_row += 1
            i_layout.addWidget(self.check_low_mem, current_row, 1, 1, 2)
            current_row += 1
            
        import os
        self.check_singularity = QCheckBox("Use Singularity (HPC Mode)")
        self.check_singularity.setChecked(False)
        self.check_singularity.setStyleSheet("color: #ffb703; font-weight: bold;")
        if os.path.exists(os.path.join(os.path.dirname(os.path.dirname(__file__)), ".enable_singularity")):
            self.check_singularity.setVisible(True)
        else:
            self.check_singularity.setVisible(False)
        i_layout.addWidget(self.check_singularity, current_row, 1, 1, 2)
        input_group.setLayout(i_layout)
        layout.addWidget(input_group)
        action_layout = QHBoxLayout()
        
        self.btn_flowchart = AnimatedButton(" View Flowchart") # Default to Secondary
        icon_flowchart = APP_ROOT / "interface" / "play.png" # reuse icon or leave empty
        self.btn_flowchart.clicked.connect(self.show_flowchart)
        action_layout.addWidget(self.btn_flowchart)
        
        if hasattr(self, 'check_prebuilt'):
            # Build indexes - Warning style
            self.btn_build = AnimatedButton("Build Reference Indexes", "rgba(232, 149, 88, 0.3)", "rgba(232, 149, 88, 0.5)", "rgba(232, 149, 88, 0.1)", "rgba(255, 255, 255, 0.9)", "rgba(232, 149, 88, 0.5)")
            self.btn_build.setEnabled(False)
            self.btn_build.clicked.connect(self.build_indexes)
            action_layout.addWidget(self.btn_build)
        # Run pipeline - Brand style
        self.btn_run = AnimatedButton(" Run Pipeline", "rgba(24, 86, 255, 0.3)", "rgba(24, 86, 255, 0.5)", "rgba(24, 86, 255, 0.1)", "rgba(255, 255, 255, 0.9)", "rgba(24, 86, 255, 0.5)")
        icon_play = APP_ROOT / "interface" / "play.png"
        if os.path.exists(icon_play): self.btn_run.setIcon(QIcon(str(icon_play)))
        else: self.btn_run.setIcon(self.style().standardIcon(QStyle.SP_MediaPlay))
        
        self.btn_run.clicked.connect(self.run_pipeline)
        action_layout.addWidget(self.btn_run)
        # Stop - Danger style
        self.btn_stop = AnimatedButton(" Stop", "rgba(234, 33, 67, 0.2)", "rgba(234, 33, 67, 0.4)", "rgba(234, 33, 67, 0.1)", "rgba(255, 255, 255, 0.9)", "rgba(234, 33, 67, 0.5)")
        icon_stop = APP_ROOT / "interface" / "stop.png"
        if os.path.exists(icon_stop): self.btn_stop.setIcon(QIcon(str(icon_stop)))
        else: self.btn_stop.setIcon(self.style().standardIcon(QStyle.SP_MediaStop))
        
        self.btn_stop.setEnabled(False)
        self.btn_stop.clicked.connect(self.parent_gui.stop_process)
        action_layout.addWidget(self.btn_stop)
        layout.addLayout(action_layout)
        if hasattr(self, 'check_prebuilt'):
            self.toggle_build_btn(2 if self.check_prebuilt.isChecked() else 0)
        layout.addStretch()
    def on_gpu_toggled(self, state):
        if hasattr(self, 'check_low_mem'):
            self.check_low_mem.setVisible(self.check_gpu.isChecked() and self.check_gpu.isEnabled())
    def get_actual_pipeline_name(self):
        if self.pipeline_type == "scRNA-seq":
            return "scRNA-seq"
        if hasattr(self, 'check_gpu') and self.check_gpu.isChecked() and self.check_gpu.isEnabled():
            return f"{self.pipeline_type} GPU"
        else:
            return f"{self.pipeline_type} CPU"
    def show_flowchart(self):
        actual_type = self.get_actual_pipeline_name()
        self.flowchart = FlowchartViewer(actual_type, self.parent_gui)
        self.flowchart.show()
    def browse_ref(self):
        folder = QFileDialog.getExistingDirectory(self, "Select Reference Folder")
        if folder: self.input_ref_dir.setText(os.path.normpath(folder))
    def browse_gtf(self):
        from PySide6.QtWidgets import QFileDialog
        f, _ = QFileDialog.getOpenFileName(self, "Select GTF File", "", "GTF Files (*.gtf *.gff)")
        if f:
            self.input_gtf.setText(os.path.normpath(f))
    def browse_fastq(self):
        folder = QFileDialog.getExistingDirectory(self, "Select FASTQ Folder")
        if folder: self.input_fastq_dir.setText(os.path.normpath(folder))
    def browse_sample(self):
        file, _ = QFileDialog.getOpenFileName(self, "Select Samplesheet", "", "CSV Files (*.csv)")
        if file: self.input_sample.setText(os.path.normpath(file))
    def toggle_build_btn(self, state):
        if hasattr(self, 'btn_build'):
            if state == 2:
                self.btn_build.setEnabled(False)
            else:
                self.btn_build.setEnabled(True)
    def build_indexes(self):
        if not self.input_ref_name.text() or not self.input_ref_dir.text():
            QMessageBox.warning(self, "Error", "Reference Name and Folder are required.")
            return
        ref_dir = self.parent_gui.to_linux_path(self.input_ref_dir.text().strip())
        ref_name = self.input_ref_name.text().strip()
        if "RNA-seq" in self.pipeline_type or "scRNA-seq" in self.pipeline_type:
            gtf_path = ""
            if hasattr(self, 'input_gtf'):
                gtf_path = self.parent_gui.to_linux_path(self.input_gtf.text().strip())
            script = APP_ROOT / "pipelines" / "rnaseq_cpu" / "RNAseq_reference_builder.sh"
            cmd = ["bash", str(script).replace("\\", "/"), ref_dir, ref_name, gtf_path]
        else:
            script = APP_ROOT / "pipelines" / "germline_cpu" / "Germline_CPU_reference_builder.sh"
            cmd = ["bash", str(script).replace("\\", "/"), ref_dir, ref_name]
        
        self.parent_gui.start_process(cmd, self.btn_run, self.btn_stop, self.btn_build)
    def run_pipeline(self):
        if not all([self.input_name.text(), self.input_ref_name.text(), self.input_ref_dir.text(), self.input_fastq_dir.text()]):
            QMessageBox.warning(self, "Error", "Project Name, Reference Name, Reference Folder, and FASTQ Folder are required.")
            return
        if ("RNA-seq" in self.pipeline_type or "scRNA-seq" in self.pipeline_type):
            if hasattr(self, 'input_gtf') and not self.input_gtf.text().strip():
                QMessageBox.warning(self, "Error", "Annotation (GTF) file path is required for RNA/scRNA pipelines.")
                return
        name = self.input_name.text().strip()
        ref_dir = self.parent_gui.to_linux_path(self.input_ref_dir.text().strip())
        ref_name = self.input_ref_name.text().strip()
        fastq_dir = self.parent_gui.to_linux_path(self.input_fastq_dir.text().strip())
        res_dir = self.parent_gui.to_linux_path(self.parent_gui.input_out_dir.text().strip())
        env = {
            "REF_DIR": ref_dir,
            "REF_NAME": ref_name,
            "RESULTS_DIR": res_dir,
            "MAX_CPUS": str(self.parent_gui.alloc_cpus),
            "MAX_MEM_GB": str(self.parent_gui.alloc_mem)
        }
        if hasattr(self, 'input_gtf'):
            gtf_path = self.parent_gui.to_linux_path(self.input_gtf.text().strip())
            if gtf_path:
                env["REF_GTF"] = gtf_path
        actual_type = self.get_actual_pipeline_name()
        if hasattr(self, 'check_prebuilt'):
            env["SKIP_INDEXING"] = "1" if self.check_prebuilt.isChecked() else "0"
            
        if "GPU" in actual_type:
            if hasattr(self, 'check_low_mem') and self.check_low_mem.isChecked():
                env["LOW_MEMORY"] = "1"
        if actual_type == "Germline CPU":
            script = APP_ROOT / "pipelines" / "germline_cpu" / "Germline_CPU_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "1"
        elif actual_type == "Germline GPU":
            script = APP_ROOT / "pipelines" / "germline_gpu" / "Germline_pipeline_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "2"
        elif actual_type == "ChIP-seq GPU":
            script = APP_ROOT / "pipelines" / "chipseq" / "CHIPseq_GPU_run.sh"
            sample = self.parent_gui.to_linux_path(self.input_sample.text().strip()) if self.input_sample.text().strip() else ""
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir, sample]
            singularity_num = "3"
        elif actual_type == "ChIP-seq CPU":
            script = APP_ROOT / "pipelines" / "chipseq_cpu" / "CHIPseq_CPU_run.sh"
            sample = self.parent_gui.to_linux_path(self.input_sample.text().strip()) if self.input_sample.text().strip() else ""
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir, sample]
            singularity_num = "4"
        elif actual_type == "RNA-seq CPU":
            script = APP_ROOT / "pipelines" / "rnaseq_cpu" / "RNAseq_CPU_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "5"
        elif actual_type == "RNA-seq GPU":
            script = APP_ROOT / "pipelines" / "rnaseq_gpu" / "RNAseq_GPU_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "6"
        elif actual_type == "Somatic CPU":
            script = APP_ROOT / "pipelines" / "somatic_cpu" / "Somatic_CPU_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "7"
        elif actual_type == "Somatic GPU":
            script = APP_ROOT / "pipelines" / "somatic_gpu" / "Somatic_GPU_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "8"
        elif actual_type == "scRNA-seq":
            script = APP_ROOT / "pipelines" / "scrnaseq_cpu" / "scRNAseq_CPU_run.sh"
            cmd = ["bash", str(script).replace("\\", "/"), name, fastq_dir]
            singularity_num = "9"
        if hasattr(self, 'check_singularity') and self.check_singularity.isChecked() and self.check_singularity.isVisible():
            script = APP_ROOT / "run_singularity.sh"
            cmd = ["bash", str(script).replace("\\", "/"), singularity_num, fastq_dir, ref_dir, res_dir, name]
        btn_bld = self.btn_build if hasattr(self, 'btn_build') else None
        self.parent_gui.start_process(cmd, self.btn_run, self.btn_stop, btn_bld, env)
class TitleBar(QWidget):
    def __init__(self, parent):
        super().__init__(parent)
        self.parent_gui = parent
        self.setFixedHeight(32)
        self.setStyleSheet("background-color: #000000;")
        
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        
        self.lbl_title = QLabel("  Nextflow Genomics GUI")
        self.lbl_title.setStyleSheet("color: #b3b3b3; font-family: 'Segoe UI'; font-size: 12px;")
        
        self.btn_min = QPushButton("—")
        self.btn_max = QPushButton("◻")
        self.btn_close = QPushButton("✕")
        
        for btn in [self.btn_min, self.btn_max, self.btn_close]:
            btn.setFixedSize(46, 32)
            btn.setCursor(Qt.ArrowCursor)
            
        self.btn_min.setStyleSheet("""
            QPushButton { background: transparent; color: #b3b3b3; border: none; font-size: 14px; border-radius: 0px; padding: 0px; }
            QPushButton:hover { background: #2a2a2a; color: white; }
            QPushButton:pressed { background: #3a3a3a; color: white; }
        """)
        self.btn_max.setStyleSheet("""
            QPushButton { background: transparent; color: #b3b3b3; border: none; font-size: 14px; border-radius: 0px; padding: 0px; }
            QPushButton:hover { background: #2a2a2a; color: white; }
            QPushButton:pressed { background: #3a3a3a; color: white; }
        """)
        self.btn_close.setStyleSheet("""
            QPushButton { background: transparent; color: #b3b3b3; border: none; font-size: 14px; border-radius: 0px; padding: 0px; }
            QPushButton:hover { background: #e81123; color: white; }
            QPushButton:pressed { background: #8b0a14; color: white; }
        """)
        
        layout.addWidget(self.lbl_title)
        layout.addStretch()
        layout.addWidget(self.btn_min)
        layout.addWidget(self.btn_max)
        layout.addWidget(self.btn_close)
        
        self.btn_min.clicked.connect(self.parent_gui.showMinimized)
        self.btn_max.clicked.connect(self.toggle_max)
        self.btn_close.clicked.connect(self.parent_gui.close)
        
        self.start_pos = None
    def toggle_max(self):
        if self.parent_gui.isMaximized():
            self.parent_gui.showNormal()
            self.btn_max.setText("◻")
        else:
            self.parent_gui.showMaximized()
            self.btn_max.setText("❐")
    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.start_pos = event.globalPosition().toPoint()
    def mouseMoveEvent(self, event):
        if self.start_pos is not None:
            delta = event.globalPosition().toPoint() - self.start_pos
            self.parent_gui.move(self.parent_gui.pos() + delta)
            self.start_pos = event.globalPosition().toPoint()
    def mouseReleaseEvent(self, event):
        self.start_pos = None
        
    def mouseDoubleClickEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.toggle_max()
class NextflowGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Window)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setWindowTitle("Nextflow Genomics GUI")
        self.resize(1000, 800)
        
        try:
            import ctypes
            DWMWA_USE_IMMERSIVE_DARK_MODE = 20
            set_window_attribute = ctypes.windll.dwmapi.DwmSetWindowAttribute
            hwnd = self.winId()
            rendering_policy = ctypes.c_int(1)
            set_window_attribute(int(hwnd), DWMWA_USE_IMMERSIVE_DARK_MODE, ctypes.byref(rendering_policy), ctypes.sizeof(rendering_policy))
        except Exception:
            pass
        
        sys_cpus = psutil.cpu_count(logical=True) or 4
        avail_mem_gb = int(psutil.virtual_memory().available / (1024**3))
        self.alloc_cpus = max(1, int(sys_cpus * 0.75))
        self.alloc_mem = max(2, int(avail_mem_gb * 0.75))
        self.process = None
        self.active_run_btn = None
        self.active_stop_btn = None
        self.active_build_btn = None
        self.setup_ui()
        QTimer.singleShot(1000, self.check_gpu_visibility)
    def check_gpu_visibility(self):
        try:
            cmd = ["docker", "run", "--rm", "--runtime=nvidia", "nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1", "nvidia-smi"]
            # Hide console window on Windows
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=10, startupinfo=startupinfo)
            if res.returncode != 0:
                QMessageBox.warning(self, "GPU Visibility Warning", "Docker failed to access the GPU using the NVIDIA runtime.\nPlease ensure NVIDIA Container Toolkit is correctly installed and configured.\n\nError output:\n" + res.stderr)
        except Exception as e:
            # Don't show an error if Docker is just not running, another part of the app might handle that
            pass
    def setup_ui(self):
        main_widget = QWidget()
        main_widget.setObjectName("main_widget")
        main_widget.setStyleSheet("#main_widget { background-color: #000000; border: 1px solid #333333; border-radius: 20px; }")
        self.setCentralWidget(main_widget)
        
        wrapper_layout = QVBoxLayout(main_widget)
        wrapper_layout.setContentsMargins(1, 1, 1, 1)
        wrapper_layout.setSpacing(0)
        
        self.title_bar = TitleBar(self)
        wrapper_layout.addWidget(self.title_bar)
        
        content_widget = QWidget()
        main_layout = QVBoxLayout(content_widget)
        main_layout.setContentsMargins(20, 20, 20, 20)
        main_layout.setSpacing(15)
        wrapper_layout.addWidget(content_widget)
        top_bar = QHBoxLayout()
        title = QLabel("Genomics Pipeline Manager")
        title.setStyleSheet("font-size: 24px; font-weight: bold; color: #ffffff; letter-spacing: -0.5px;")
        
        self.btn_toggle_console = AnimatedButton(" Show Terminal")
        icon_term = APP_ROOT / "interface" / "terminal.png"
        if os.path.exists(icon_term): self.btn_toggle_console.setIcon(QIcon(str(icon_term)))
        else: self.btn_toggle_console.setIcon(self.style().standardIcon(QStyle.SP_ComputerIcon))
        self.btn_toggle_console.setCheckable(True)
        self.btn_toggle_console.clicked.connect(self.toggle_console)
        
        top_bar.addWidget(title)
        top_bar.addStretch()
        top_bar.addWidget(self.btn_toggle_console)
        main_layout.addLayout(top_bar)
        out_group = QGroupBox("Global Output Directory")
        out_layout = QHBoxLayout()
        out_label = QLabel("Save Results To:")
        out_label.setFixedWidth(120)
        self.input_out_dir = QLineEdit(str(RESULTS_DIR))
        self.btn_browse_out = QPushButton("Browse...")
        self.btn_browse_out.clicked.connect(self.browse_out)
        out_layout.addWidget(out_label)
        out_layout.addWidget(self.input_out_dir)
        out_layout.addWidget(self.btn_browse_out)
        out_group.setLayout(out_layout)
        main_layout.addWidget(out_group)
        self.tabs_layout = QHBoxLayout()
        self.sidebar_list = QListWidget()
        self.sidebar_list.setFixedWidth(220)
        self.tabs_stack = QStackedWidget()
        
        self.tabs_layout.addWidget(self.sidebar_list)
        self.tabs_layout.addWidget(self.tabs_stack)
        
        self.sidebar_list.currentRowChanged.connect(self.tabs_stack.setCurrentIndex)
        
        self.tab_monitor = ResourceMonitor(self)
        icon_mon = APP_ROOT / "interface" / "monitor.png"
        item_monitor = QListWidgetItem(" Resource Monitor")
        if os.path.exists(icon_mon): item_monitor.setIcon(QIcon(str(icon_mon)))
        else: item_monitor.setIcon(self.style().standardIcon(QStyle.SP_ComputerIcon))
        self.sidebar_list.addItem(item_monitor)
        self.tabs_stack.addWidget(self.tab_monitor)
        
        self.tab_germline = PipelineTab("Germline", self)
        self.tab_chipseq = PipelineTab("ChIP-seq", self)
        self.tab_rnaseq = PipelineTab("RNA-seq", self)
        self.tab_somatic = PipelineTab("Somatic", self)
        self.tab_scrnaseq = PipelineTab("scRNA-seq", self)
        
        for name, widget in [
            ("Germline", self.tab_germline),
            ("ChIP-seq", self.tab_chipseq),
            ("RNA-seq", self.tab_rnaseq),
            ("Somatic", self.tab_somatic),
            ("scRNA-seq", self.tab_scrnaseq)
        ]:
            self.sidebar_list.addItem(name)
            self.tabs_stack.addWidget(widget)
            
        main_layout.addLayout(self.tabs_layout)
        # Create a detached standalone window for the console
        self.console_window = QDialog(self)
        self.console_window.setWindowTitle("Pipeline Execution Terminal")
        self.console_window.resize(800, 600)
        c_layout = QVBoxLayout(self.console_window)
        self.console = QTextEdit()
        self.console.setReadOnly(True)
        self.console.setFont(QFont("Consolas", 10))
        self.console.setStyleSheet("background-color: #000000; color: #00fa9a;")
        c_layout.addWidget(self.console)
        
        # We don't add console_group to main_layout anymore
        
        # Override close event of console window to uncheck the button
        def on_console_close(event):
            self.btn_toggle_console.setChecked(False)
            self.toggle_console()
        self.console_window.closeEvent = on_console_close
        
        # Progress Bar Layout
        prog_layout = QVBoxLayout()
        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.progress_bar.setTextVisible(False)
        self.progress_bar.setFixedHeight(8)
        self.progress_bar.setStyleSheet("""
            QProgressBar {
                border: none;
                background-color: #2a2a2a;
                border-radius: 4px;
            }
            QProgressBar::chunk {
                background-color: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #00f2fe, stop:1 #4facfe);
                border-radius: 4px;
            }
        """)
        
        self.lbl_status = QLabel("Idle.")
        self.lbl_status.setStyleSheet("color: #b3b3b3; font-size: 12px; font-style: italic;")
        
        prog_layout.addWidget(self.progress_bar)
        prog_layout.addWidget(self.lbl_status)
        main_layout.addLayout(prog_layout)
        bottom_layout = QHBoxLayout()
        bottom_layout.addStretch()
        size_grip = QSizeGrip(self)
        bottom_layout.addWidget(size_grip)
        wrapper_layout.addLayout(bottom_layout)
    def browse_out(self):
        folder = QFileDialog.getExistingDirectory(self, "Select Output Directory")
        if folder: self.input_out_dir.setText(os.path.normpath(folder))
    def toggle_console(self):
        is_visible = self.btn_toggle_console.isChecked()
        if is_visible:
            self.console_window.show()
            self.btn_toggle_console.setText(" Hide Terminal")
            self.btn_toggle_console.setStyleSheet("""
QPushButton {
    background: #00ced1; color: black; font-weight: bold; padding: 12px 24px; border-radius: 20px; border: none;
}
QPushButton:hover {
    background: #20ded1;
}
QPushButton:pressed {
    background: #00aeab;
}
""")
        else:
            self.console_window.hide()
            self.btn_toggle_console.setText(" Show Terminal")
            self.btn_toggle_console.setStyleSheet("""
QPushButton {
    background: #282828; color: white; font-weight: bold; padding: 12px 24px; border-radius: 20px; border: none;
}
QPushButton:hover {
    background: #3e3e3e;
}
QPushButton:pressed {
    background: #1a1a1a;
}
""")
    def to_linux_path(self, path_str):
        path = path_str.replace('\\', '/')
        if len(path) > 1 and path[1] == ':':
            drive = path[0].lower()
            path = f"/mnt/{drive}{path[2:]}"
        return path
    def append_console(self, text):
        self.console.moveCursor(QTextCursor.End)
        self.console.insertPlainText(text)
        self.console.moveCursor(QTextCursor.End)
    def start_process(self, command, run_btn, stop_btn, build_btn=None, env_dict=None):
        if self.process and self.process.state() == QProcess.Running:
            QMessageBox.warning(self, "Warning", "A process is already running!")
            return
        if not self.btn_toggle_console.isChecked():
            self.btn_toggle_console.setChecked(True)
            self.toggle_console()
        self.console.clear()
        self.current_log = ""
        self.append_console(f"Running command: {' '.join(command)}\n")
        self.append_console("-" * 60 + "\n")
        self.active_run_btn = run_btn
        self.active_stop_btn = stop_btn
        self.active_build_btn = build_btn
        self.process = QProcess()
        env = QProcessEnvironment.systemEnvironment()
        if env_dict:
            for k, v in env_dict.items():
                env.insert(k, v)
        self.process.setProcessEnvironment(env)
        
        self.process.readyReadStandardOutput.connect(self.handle_stdout)
        self.process.readyReadStandardError.connect(self.handle_stderr)
        self.process.finished.connect(self.process_finished)
        run_btn.setEnabled(False)
        if build_btn: build_btn.setEnabled(False)
        stop_btn.setEnabled(True)
        self.progress_bar.setRange(0, 0)
        self.lbl_status.setText("Initializing Nextflow environment...")
        self.process.start(command[0], command[1:])
    def handle_stdout(self):
        data = self.process.readAllStandardOutput()
        text = bytes(data).decode("utf-8", errors="replace")
        self.current_log += text
        self.append_console(text)
        
        # Parse for tool name
        for line in text.split('\n'):
            if ']' in line and '|' in line:
                match = re.search(r'\]\s+([A-Z0-9_]+)\s*\(', line)
                if not match:
                    match = re.search(r'\]\s+([A-Z0-9_]+)\s*\|', line)
                if match:
                    tool = match.group(1)
                    desc_map = {
                        "FASTQC": "FastQC: Analyzing raw read quality...",
                        "FASTP": "fastp: Trimming adapters and filtering reads...",
                        "BWA_ALIGN": "BWA-MEM: Aligning reads to the reference genome...",
                        "FQ2BAM": "Parabricks fq2bam: GPU-accelerated alignment and sorting...",
                        "SORT_BAM": "Samtools: Sorting BAM files...",
                        "MARK_DUPLICATES": "GATK MarkDuplicates: Tagging duplicate reads...",
                        "INDEX_BAM": "Samtools: Indexing BAM files...",
                        "MACS2": "MACS2: Calling peaks...",
                        "HAPLOTYPE_CALLER": "GATK HaplotypeCaller: Calling variants...",
                        "DEEPVARIANT": "Parabricks DeepVariant: GPU-accelerated variant calling...",
                        "GENOTYPE_GVCFS": "GATK: Joint Genotyping cohorts...",
                        "VARIANT_FILTRATION": "GATK: Hard filtering variants...",
                        "PASS_VCF": "Extracting PASS variants...",
                        "COMBINE_GVCFS": "GATK CombineGVCFs: Merging variant calls..."
                    }
                    if tool in desc_map:
                        self.lbl_status.setText(desc_map[tool])
    def handle_stderr(self):
        data = self.process.readAllStandardError()
        text = bytes(data).decode("utf-8", errors="replace")
        self.current_log += text
        self.append_console(text)
    def process_finished(self, exit_code, exit_status):
        self.append_console("-" * 60 + "\n")
        self.append_console(f"Process finished with exit code {exit_code}\n")
        if self.active_run_btn: self.active_run_btn.setEnabled(True)
        if self.active_stop_btn: self.active_stop_btn.setEnabled(False)
        if self.active_build_btn: self.active_build_btn.setEnabled(True)
        if exit_code != 0:
            self.progress_bar.setRange(0, 100)
            self.progress_bar.setValue(0)
            self.lbl_status.setText("Failed.")
            
            log_lower = self.current_log.lower()
            if "cannot connect to the docker daemon" in log_lower or "docker daemon is not running" in log_lower:
                title = "Docker Connection Error"
                msg = "The pipeline cannot connect to the Docker daemon.\n\nSolution: Please ensure Docker Desktop is installed, open, and running in the background before starting the pipeline."
            elif "no space left on device" in log_lower:
                title = "Disk Space Error"
                msg = "Your system has run out of disk space.\n\nSolution: Please clear up storage on your hard drive. Docker images and BAM files require significant free space (at least 50-100GB recommended)."
            elif "cuda_error_out_of_memory" in log_lower or "parabricks: error" in log_lower or "cuda out of memory" in log_lower:
                title = "GPU Out of Memory"
                msg = "The NVIDIA Parabricks GPU pipeline ran out of Video RAM (VRAM).\n\nSolution: Try checking the 'Low Memory Mode' box in the GUI, or uncheck the 'Use GPU Acceleration' checkbox to run on CPU."
            elif "exit code 137" in log_lower or "outofmemoryerror" in log_lower or "insufficient resources" in log_lower:
                title = "System Out of Memory"
                msg = "The pipeline ran out of System RAM.\n\nSolution: Lower the Memory Limit slider in the Resource Monitor, close background applications, or ensure your system has enough physical RAM."
            elif "zerodivisionerror" in log_lower or "empty bam" in log_lower or "zero mapped reads" in log_lower:
                title = "No Mapped Reads Error"
                msg = "Zero reads successfully mapped to the reference genome.\n\nSolution: Verify that you selected the correct Reference Fasta for your FASTQ dataset (e.g., don't use hg38 for mouse data). Check the FastQC reports for data quality."
            elif "not found" in log_lower and (".bwt" in log_lower or ".fai" in log_lower or ".dict" in log_lower):
                title = "Missing Reference Index"
                msg = "Required reference genome indices were not found.\n\nSolution: Please click the 'Build Reference Index' button in the GUI first before running the pipeline."
            else:
                title = "Pipeline Execution Error"
                msg = f"The pipeline failed with an unknown error (Exit Code: {exit_code}).\n\nSolution: Please read the Terminal log for specific clues or check the Nextflow '.nextflow.log' file."
            
            QMessageBox.critical(self, title, msg)
        else:
            self.progress_bar.setRange(0, 100)
            self.progress_bar.setValue(100)
            self.lbl_status.setText("Complete!")
            
            reply = QMessageBox.question(
                self, 
                "Success", 
                "Pipeline execution completed successfully!\nDo you want to open the results folder?",
                QMessageBox.Yes | QMessageBox.No, 
                QMessageBox.Yes
            )
            
            if reply == QMessageBox.Yes:
                res_path = self.input_out_dir.text()
                if os.path.exists(res_path):
                    if sys.platform == "win32":
                        os.startfile(res_path)
                    elif sys.platform == "darwin":
                        subprocess.call(["open", res_path])
                    else:
                        subprocess.call(["xdg-open", res_path])
    def stop_process(self):
        if self.process and self.process.state() == QProcess.Running:
            self.append_console("\nStopping process...\n")
            self.process.kill()
if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setStyleSheet(MODERN_QSS)
    window = NextflowGUI()
    window.show()
    sys.exit(app.exec())
