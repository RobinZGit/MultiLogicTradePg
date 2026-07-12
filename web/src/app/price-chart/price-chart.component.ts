import {
  AfterViewInit,
  Component,
  ElementRef,
  EventEmitter,
  HostListener,
  Input,
  OnChanges,
  OnDestroy,
  Output,
  SimpleChanges,
  ViewChild,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import {
  ChartIndicatorSeries,
  ChartVisibleRange,
  PriceCandle,
} from '../models/market.model';

@Component({
  selector: 'app-price-chart',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './price-chart.component.html',
  styleUrl: './price-chart.component.css',
})
export class PriceChartComponent implements AfterViewInit, OnChanges, OnDestroy {
  @ViewChild('canvas') canvasRef!: ElementRef<HTMLCanvasElement>;
  @ViewChild('chartBody') chartBodyRef!: ElementRef<HTMLDivElement>;

  @Input() candles: PriceCandle[] = [];
  @Input() indicatorSeries: ChartIndicatorSeries[] = [];
  @Input() loading = false;
  @Input() error: string | null = null;
  @Input() title = '';

  @Output() loadOlder = new EventEmitter<void>();
  @Output() visibleRangeChange = new EventEmitter<ChartVisibleRange>();
  @Output() recalcIndicators = new EventEmitter<ChartVisibleRange>();

  fullscreen = false;

  private viewStart = 0;
  private readonly baseCandleWidth = 7;
  private zoom = 1;

  private dragging = false;
  private dragStartX = 0;
  private dragStartView = 0;
  private resizeObserver: ResizeObserver | null = null;
  private prevCandlesLen = 0;
  private loadOlderPending = false;
  private emitRangeTimer: ReturnType<typeof setTimeout> | null = null;

  private pinchActive = false;
  private pinchStartDist = 0;
  private pinchStartZoom = 1;

  /** Масштаб подписей осей, легенды и даты в полноэкранном режиме */
  private get labelScale(): number {
    return this.fullscreen ? 1.55 : 1;
  }

  private chartPadding(): { top: number; right: number; bottom: number; left: number } {
    const s = this.labelScale;
    return {
      top: Math.round(28 * s),
      right: 10,
      bottom: Math.round(22 * s),
      left: Math.round(52 * s),
    };
  }

  private px(base: number): number {
    return Math.round(base * this.labelScale);
  }

  ngAfterViewInit(): void {
    const body = this.chartBodyRef?.nativeElement;
    if (!body) return;
    this.resizeObserver = new ResizeObserver(() => this.redraw());
    this.resizeObserver.observe(body);
    this.redraw();
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['candles']) {
      const added = this.candles.length - this.prevCandlesLen;
      if (added > 0 && this.prevCandlesLen > 0 && this.viewStart > 0) {
        this.viewStart += added;
      }
      this.prevCandlesLen = this.candles.length;
      this.loadOlderPending = false;
      this.clampViewStart();
      if (this.candles.length > 0) {
        this.scheduleEmitVisibleRange();
      }
    }
    queueMicrotask(() => this.redraw());
  }

  ngOnDestroy(): void {
    this.resizeObserver?.disconnect();
    if (this.emitRangeTimer) clearTimeout(this.emitRangeTimer);
    if (this.fullscreen) {
      document.body.style.overflow = '';
    }
  }

  @HostListener('document:keydown.escape')
  onEscape(): void {
    if (this.fullscreen) this.closeFullscreen();
  }

  get candleWidth(): number {
    return Math.min(24, Math.max(3, this.baseCandleWidth * this.zoom));
  }

  openFullscreen(): void {
    this.fullscreen = true;
    document.body.style.overflow = 'hidden';
    queueMicrotask(() => {
      this.clampViewStart();
      this.redraw();
      requestAnimationFrame(() => this.scheduleEmitVisibleRange(false));
    });
  }

  closeFullscreen(): void {
    this.fullscreen = false;
    document.body.style.overflow = '';
    queueMicrotask(() => {
      this.clampViewStart();
      this.redraw();
      requestAnimationFrame(() => this.scheduleEmitVisibleRange(false));
    });
  }

  onRecalcClick(event: Event): void {
    event.stopPropagation();
    this.recalcIndicators.emit({
      ...this.currentVisibleRange(),
      userInitiated: true,
    });
  }

  panLeft(event: Event): void {
    event.stopPropagation();
    this.shiftView(-Math.max(5, Math.floor(this.viewCount() / 4)));
  }

  panRight(event: Event): void {
    event.stopPropagation();
    this.shiftView(Math.max(5, Math.floor(this.viewCount() / 4)));
  }

  zoomIn(event: Event): void {
    event.stopPropagation();
    this.applyZoom(this.zoom * 1.2);
  }

  zoomOut(event: Event): void {
    event.stopPropagation();
    this.applyZoom(this.zoom / 1.2);
  }

  onWheel(event: WheelEvent): void {
    if (this.loading || this.candles.length === 0) return;
    event.preventDefault();
    const factor = event.deltaY < 0 ? 1.12 : 1 / 1.12;
    this.applyZoom(this.zoom * factor);
  }

  onPointerDown(event: PointerEvent): void {
    if (this.loading || this.candles.length === 0) return;
    if (this.pinchActive) return;

    this.dragging = true;
    this.dragStartX = event.clientX;
    this.dragStartView = this.viewStart;
    (event.target as HTMLElement).setPointerCapture(event.pointerId);
  }

  onPointerMove(event: PointerEvent): void {
    if (this.pinchActive) return;
    if (!this.dragging) return;

    const delta = event.clientX - this.dragStartX;
    const shift = Math.round(-delta / this.candleWidth);
    const maxStart = Math.max(0, this.candles.length - this.viewCount());
    this.viewStart = Math.min(maxStart, Math.max(0, this.dragStartView + shift));

    if (this.viewStart <= 8 && !this.loading && !this.loadOlderPending) {
      this.loadOlderPending = true;
      this.loadOlder.emit();
    }
    this.redraw();
  }

  onPointerUp(event: PointerEvent): void {
    const moved = this.dragging && this.viewStart !== this.dragStartView;
    this.dragging = false;
    try {
      (event.target as HTMLElement).releasePointerCapture(event.pointerId);
    } catch {
      /* ignore */
    }
    if (moved) {
      this.scheduleEmitVisibleRange(true);
    }
  }

  onPointerLeave(event: PointerEvent): void {
    if (!this.dragging) return;
    this.onPointerUp(event);
  }

  onTouchStart(event: TouchEvent): void {
    if (event.touches.length === 2) {
      this.pinchActive = true;
      this.dragging = false;
      this.pinchStartDist = this.touchDistance(event.touches);
      this.pinchStartZoom = this.zoom;
      event.preventDefault();
    }
  }

  onTouchMove(event: TouchEvent): void {
    if (!this.pinchActive || event.touches.length < 2) return;
    event.preventDefault();
    const dist = this.touchDistance(event.touches);
    if (this.pinchStartDist <= 0) return;
    const ratio = dist / this.pinchStartDist;
    this.applyZoom(this.pinchStartZoom * ratio, false);
  }

  onTouchEnd(event: TouchEvent): void {
    if (event.touches.length < 2) {
      this.pinchActive = false;
      this.scheduleEmitVisibleRange(true);
    }
  }

  private touchDistance(touches: TouchList): number {
    const dx = touches[0].clientX - touches[1].clientX;
    const dy = touches[0].clientY - touches[1].clientY;
    return Math.hypot(dx, dy);
  }

  private applyZoom(next: number, emit = true): void {
    const prev = this.zoom;
    this.zoom = Math.min(3.5, Math.max(0.45, next));
    if (Math.abs(this.zoom - prev) < 0.001) return;
    this.clampViewStart();
    this.redraw();
    if (emit) this.scheduleEmitVisibleRange(true);
  }

  private shiftView(delta: number): void {
    const maxStart = Math.max(0, this.candles.length - this.viewCount());
    this.viewStart = Math.min(maxStart, Math.max(0, this.viewStart + delta));
    if (this.viewStart <= 8 && !this.loading && !this.loadOlderPending) {
      this.loadOlderPending = true;
      this.loadOlder.emit();
    }
    this.redraw();
    this.scheduleEmitVisibleRange(true);
  }

  private clampViewStart(): void {
    const maxStart = Math.max(0, this.candles.length - this.viewCount());
    if (this.viewStart + this.viewCount() > this.candles.length) {
      this.viewStart = maxStart;
    }
    if (this.viewStart > maxStart) {
      this.viewStart = maxStart;
    }
  }

  private viewCount(): number {
    const body = this.chartBodyRef?.nativeElement;
    if (!body) return 60;
    const pad = this.chartPadding();
    const w = body.clientWidth || 400;
    return Math.max(10, Math.floor((w - pad.left - pad.right) / this.candleWidth));
  }

  currentVisibleRange(): ChartVisibleRange {
    const count = this.viewCount();
    const visible = this.candles.slice(this.viewStart, this.viewStart + count);
    if (visible.length === 0) {
      return { startDt: '', endDt: '', count: 0, viewStart: this.viewStart };
    }
    return {
      startDt: visible[0].dt,
      endDt: visible[visible.length - 1].dt,
      count: visible.length,
      viewStart: this.viewStart,
    };
  }

  private scheduleEmitVisibleRange(userInitiated = false): void {
    if (this.emitRangeTimer) clearTimeout(this.emitRangeTimer);
    this.emitRangeTimer = setTimeout(() => {
      const range = this.currentVisibleRange();
      if (range.count > 0) {
        this.visibleRangeChange.emit({ ...range, userInitiated });
      }
    }, 300);
  }

  private hasOscillatorPanel(): boolean {
    return this.indicatorSeries.some((s) => !s.on_price_scale);
  }

  /** Индикаторы на шкале цены, для которых нужна явная линия y=0 (вторая разность и т.п.). */
  private priceScaleAnchorsZero(): boolean {
    return this.indicatorSeries.some(
      (s) =>
        s.on_price_scale &&
        !s.is_threshold &&
        ['PACC', 'MOM', 'ROC'].includes(s.indicator_code)
    );
  }

  private drawReferenceLevel(
    ctx: CanvasRenderingContext2D,
    yScale: (v: number) => number,
    value: number,
    minV: number,
    maxV: number,
    left: number,
    right: number,
    label: string
  ): void {
    if (value < minV || value > maxV) return;
    const y = yScale(value);
    const axisSize = this.px(10);
    ctx.strokeStyle = '#e5e7eb';
    ctx.lineWidth = 1;
    ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(left, y);
    ctx.lineTo(right, y);
    ctx.stroke();
    ctx.fillStyle = '#9ca3af';
    ctx.font = `${axisSize}px system-ui, sans-serif`;
    ctx.fillText(label, 4, y + Math.round(axisSize * 0.35));
  }

  private valueAtDt(series: ChartIndicatorSeries, dt: string): number | null {
    const point = series.points.find((p) => p.dt === dt);
    return point != null ? point.value : null;
  }

  private redraw(): void {
    const canvas = this.canvasRef?.nativeElement;
    const body = this.chartBodyRef?.nativeElement;
    if (!canvas || !body) return;

    const cssW = body.clientWidth;
    const cssH = body.clientHeight;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.floor(cssW * dpr);
    canvas.height = Math.floor(cssH * dpr);
    canvas.style.width = `${cssW}px`;
    canvas.style.height = `${cssH}px`;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);

    const pad = this.chartPadding();
    const msgSize = this.px(13);

    if (this.error) {
      ctx.fillStyle = '#b45309';
      ctx.font = `${msgSize}px system-ui, sans-serif`;
      ctx.fillText(this.error, 12, pad.top + 8);
      return;
    }
    if (this.loading && this.candles.length === 0) {
      ctx.fillStyle = '#6b7280';
      ctx.font = `${msgSize}px system-ui, sans-serif`;
      ctx.fillText('Загрузка свечей…', 12, pad.top + 8);
      return;
    }
    if (this.candles.length === 0) {
      ctx.fillStyle = '#6b7280';
      ctx.font = `${msgSize}px system-ui, sans-serif`;
      ctx.fillText('Нет цен для выбранного таймфрейма', 12, pad.top + 8);
      return;
    }

    const cw = this.candleWidth;
    const count = this.viewCount();
    const visible = this.candles.slice(this.viewStart, this.viewStart + count);
    if (visible.length === 0) return;

    const showOsc = this.hasOscillatorPanel();
    const oscRatio = showOsc ? 0.28 : 0;
    const priceTop = pad.top;
    const priceBottom = cssH - pad.bottom - cssH * oscRatio;
    const priceH = priceBottom - priceTop;
    const oscTop = priceBottom + 6;
    const oscBottom = cssH - pad.bottom;
    const oscH = Math.max(0, oscBottom - oscTop);

    let minP = Infinity;
    let maxP = -Infinity;
    for (const c of visible) {
      minP = Math.min(minP, Number(c.low_price));
      maxP = Math.max(maxP, Number(c.high_price));
    }

    const priceSeries = this.indicatorSeries.filter(
      (s) => s.on_price_scale && !s.is_threshold
    );
    for (const s of priceSeries) {
      for (const c of visible) {
        const v = this.valueAtDt(s, c.dt);
        if (v != null && Number.isFinite(v)) {
          minP = Math.min(minP, v);
          maxP = Math.max(maxP, v);
        }
      }
    }

    if (this.priceScaleAnchorsZero()) {
      minP = Math.min(minP, 0);
      maxP = Math.max(maxP, 0);
    }

    const pricePad = (maxP - minP) * 0.06 || maxP * 0.001 || 1;
    minP -= pricePad;
    maxP += pricePad;
    const yScale = (p: number) => priceTop + priceH - ((p - minP) / (maxP - minP)) * priceH;

    const axisSize = this.px(10);
    ctx.strokeStyle = '#e5e7eb';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const p = minP + ((maxP - minP) * i) / 4;
      const y = yScale(p);
      ctx.beginPath();
      ctx.moveTo(pad.left, y);
      ctx.lineTo(cssW - pad.right, y);
      ctx.stroke();
      ctx.fillStyle = '#9ca3af';
      ctx.font = `${axisSize}px system-ui, sans-serif`;
      ctx.fillText(p.toFixed(2), 4, y + Math.round(axisSize * 0.35));
    }

    this.drawReferenceLevel(
      ctx,
      yScale,
      0,
      minP,
      maxP,
      pad.left,
      cssW - pad.right,
      '0'
    );

    visible.forEach((c, i) => {
      const x = pad.left + i * cw + cw / 2;
      const open = Number(c.open_price);
      const close = Number(c.close_price);
      const high = Number(c.high_price);
      const low = Number(c.low_price);
      const up = close >= open;
      ctx.strokeStyle = up ? '#16a34a' : '#dc2626';
      ctx.fillStyle = up ? '#16a34a' : '#dc2626';

      const yHigh = yScale(high);
      const yLow = yScale(low);
      ctx.beginPath();
      ctx.moveTo(x, yHigh);
      ctx.lineTo(x, yLow);
      ctx.stroke();

      const yOpen = yScale(open);
      const yClose = yScale(close);
      const top = Math.min(yOpen, yClose);
      const bodyH = Math.max(1, Math.abs(yClose - yOpen));
      ctx.fillRect(x - cw * 0.35, top, cw * 0.7, bodyH);
    });

    for (const s of priceSeries) {
      this.drawLineSeries(ctx, visible, s, yScale, pad.left, cw);
    }

    if (showOsc && oscH > 20) {
      ctx.strokeStyle = '#d1d5db';
      ctx.beginPath();
      ctx.moveTo(pad.left, oscTop);
      ctx.lineTo(cssW - pad.right, oscTop);
      ctx.stroke();

      const oscSeries = this.indicatorSeries.filter((s) => !s.on_price_scale);
      let oscMin = Infinity;
      let oscMax = -Infinity;
      for (const s of oscSeries) {
        for (const c of visible) {
          const v = this.valueAtDt(s, c.dt);
          if (v != null && Number.isFinite(v)) {
            oscMin = Math.min(oscMin, v);
            oscMax = Math.max(oscMax, v);
          }
        }
      }
      if (!Number.isFinite(oscMin) || !Number.isFinite(oscMax)) {
        oscMin = 0;
        oscMax = 100;
      }
      oscMin = Math.min(oscMin, 0);
      oscMax = Math.max(oscMax, 0);
      const oscPad = (oscMax - oscMin) * 0.08 || 1;
      oscMin -= oscPad;
      oscMax += oscPad;
      const yOsc = (v: number) => oscTop + oscH - ((v - oscMin) / (oscMax - oscMin)) * oscH;

      this.drawReferenceLevel(
        ctx,
        yOsc,
        0,
        oscMin,
        oscMax,
        pad.left,
        cssW - pad.right,
        '0'
      );

      for (const s of oscSeries.filter((x) => x.is_threshold)) {
        this.drawThresholdLine(ctx, s, yOsc, pad.left, cssW - pad.right);
      }
      for (const s of oscSeries.filter((x) => !x.is_threshold)) {
        this.drawLineSeries(ctx, visible, s, yOsc, pad.left, cw);
      }

      ctx.fillStyle = '#9ca3af';
      ctx.font = `${this.px(9)}px system-ui, sans-serif`;
      ctx.fillText('OSC', 4, oscTop + this.px(10));
    }

    this.drawLegend(ctx, cssW, pad);

    const last = visible[visible.length - 1];
    ctx.fillStyle = '#6b7280';
    const footerSize = this.px(10);
    ctx.font = `${footerSize}px system-ui, sans-serif`;
    const dtLabel = new Date(last.dt).toLocaleString('ru-RU', {
      dateStyle: 'short',
      timeStyle: 'short',
    });
    let footer = dtLabel;
    if (last.contract_prefix) {
      footer += ` · ${last.contract_prefix}`;
      if (last.group_prefix && last.group_prefix !== last.contract_prefix) {
        footer += ` (гр. ${last.group_prefix})`;
      }
    }
    ctx.fillText(footer, pad.left, cssH - Math.round(pad.bottom * 0.25));

    if (this.loading) {
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.fillRect(0, 0, cssW, cssH);
      ctx.fillStyle = '#374151';
      ctx.font = `${this.px(12)}px system-ui, sans-serif`;
      ctx.fillText('Обновление…', cssW / 2 - this.px(40), cssH / 2);
    }
  }

  private drawLineSeries(
    ctx: CanvasRenderingContext2D,
    visible: PriceCandle[],
    series: ChartIndicatorSeries,
    yScale: (v: number) => number,
    left: number,
    candleWidth: number
  ): void {
    ctx.strokeStyle = series.color;
    ctx.lineWidth = series.is_threshold ? 1 : 1.5;
    ctx.setLineDash(series.is_threshold ? [4, 4] : []);
    ctx.beginPath();
    let started = false;
    visible.forEach((c, i) => {
      const v = this.valueAtDt(series, c.dt);
      if (v == null || !Number.isFinite(v)) {
        started = false;
        return;
      }
      const x = left + i * candleWidth + candleWidth / 2;
      const y = yScale(v);
      if (!started) {
        ctx.moveTo(x, y);
        started = true;
      } else {
        ctx.lineTo(x, y);
      }
    });
    ctx.stroke();
    ctx.setLineDash([]);
  }

  private drawThresholdLine(
    ctx: CanvasRenderingContext2D,
    series: ChartIndicatorSeries,
    yScale: (v: number) => number,
    left: number,
    right: number
  ): void {
    const v = series.points[0]?.value;
    if (v == null || !Number.isFinite(v)) return;
    ctx.strokeStyle = series.color;
    ctx.lineWidth = 1;
    ctx.setLineDash([5, 4]);
    const y = yScale(v);
    ctx.beginPath();
    ctx.moveTo(left, y);
    ctx.lineTo(right, y);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  private drawLegend(
    ctx: CanvasRenderingContext2D,
    cssW: number,
    pad: { left: number }
  ): void {
    const drawn = this.indicatorSeries.filter((s) => !s.is_threshold);
    if (drawn.length === 0) return;
    let x = pad.left;
    const y = this.px(18);
    const legendSize = this.px(9);
    const swatchW = this.px(10);
    const swatchH = Math.max(3, this.px(3));
    ctx.font = `${legendSize}px system-ui, sans-serif`;
    for (const s of drawn.slice(0, 8)) {
      const label = `${s.indicator_code}.${s.line_code}`;
      ctx.fillStyle = s.color;
      ctx.fillRect(x, y - swatchH - 2, swatchW, swatchH);
      ctx.fillStyle = '#374151';
      ctx.fillText(label, x + swatchW + 3, y);
      x += ctx.measureText(label).width + this.px(22);
      if (x > cssW - 80) break;
    }
  }
}
