import { ComponentFixture, TestBed } from '@angular/core/testing';
import { PriceChartComponent } from './price-chart.component';

describe('PriceChartComponent', () => {
  let fixture: ComponentFixture<PriceChartComponent>;
  let component: PriceChartComponent;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [PriceChartComponent],
    }).compileComponents();

    fixture = TestBed.createComponent(PriceChartComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('shows error text when error is set', () => {
    component.loading = false;
    component.candles = [];
    component.error = 'Нет свечей — нажмите «Загрузить цены»';
    component.ngOnChanges({
      error: {
        currentValue: component.error,
        previousValue: null,
        firstChange: true,
        isFirstChange: () => true,
      },
    });
    fixture.detectChanges();
    expect(component.error).toContain('Загрузить цены');
  });

  it('does not emit loadOlder when there are no candles', () => {
    const spy = jasmine.createSpy('loadOlder');
    component.loadOlder.subscribe(spy);
    component.candles = [];
    component.loading = false;

    const event = new PointerEvent('pointerdown', { clientX: 100 });
    component.onPointerDown(event);

    expect(spy).not.toHaveBeenCalled();
  });

  it('emits recalcIndicators with visible range', () => {
    const spy = jasmine.createSpy('recalc');
    component.recalcIndicators.subscribe(spy);
    component.candles = [
      { dt: '2026-01-01T10:00:00', open_price: 1, high_price: 1, low_price: 1, close_price: 1, volume: 1 },
      { dt: '2026-01-01T10:15:00', open_price: 2, high_price: 2, low_price: 2, close_price: 2, volume: 1 },
    ];
    component.ngOnChanges({
      candles: {
        currentValue: component.candles,
        previousValue: [],
        firstChange: true,
        isFirstChange: () => true,
      },
    });
    component.onRecalcClick(new Event('click'));
    expect(spy).toHaveBeenCalled();
    expect(spy.calls.mostRecent().args[0].count).toBeGreaterThan(0);
  });

  it('opens and closes fullscreen', () => {
    component.openFullscreen();
    expect(component.fullscreen).toBeTrue();
    component.closeFullscreen();
    expect(component.fullscreen).toBeFalse();
  });
});
