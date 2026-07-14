import { ComponentFixture, TestBed } from '@angular/core/testing';
import { of } from 'rxjs';
import { LogicBacktestPapersComponent } from './logic-backtest-papers.component';
import { SecuritiesService } from '../services/securities.service';
import { LogicTradeRow } from '../shared/logic-trade';

describe('LogicBacktestPapersComponent', () => {
  let fixture: ComponentFixture<LogicBacktestPapersComponent>;
  let component: LogicBacktestPapersComponent;
  let api: jasmine.SpyObj<SecuritiesService>;

  const sampleTrade: LogicTradeRow = {
    id: 1,
    logic_id: 1,
    account_id: 1,
    security_id: 7,
    timeframe_id: 6,
    side_id: 1,
    action_id: 1,
    signal_kind: 'trend',
    signal_formula: '',
    quantity: 1,
    price: 100,
    bar_dt: '2026-04-10 10:00:00',
    executed_at: '2026-04-10 10:00:00',
    is_simulated: true,
    is_shadow: false,
    is_test: true,
    trade_reason: null,
    broker_order_id: null,
    status: 'filled',
    commission: 0,
    financial_result: 25,
    note: null,
    security_name: 'SBER',
    security_prefix: 'SBER',
    side_name: 'Close',
    action_name: 'Long',
    timeframe_tf: 'M15',
  };

  beforeEach(async () => {
    api = jasmine.createSpyObj('SecuritiesService', [
      'getPrices',
      'getSecurityIndicatorSeries',
      'getIndicatorValues',
      'syncIndicatorSeries',
    ]);
    api.getPrices.and.returnValue(
      of([
        {
          dt: '2026-04-10 10:00:00',
          open_price: 100,
          high_price: 101,
          low_price: 99,
          close_price: 100.5,
          volume: 1,
        },
      ])
    );
    api.getIndicatorValues.and.returnValue(of([]));
    api.syncIndicatorSeries.and.returnValue(of({ ok: true, status: 'accepted' }));

    await TestBed.configureTestingModule({
      imports: [LogicBacktestPapersComponent],
      providers: [{ provide: SecuritiesService, useValue: api }],
    }).compileComponents();

    fixture = TestBed.createComponent(LogicBacktestPapersComponent);
    component = fixture.componentInstance;
    component.trades = [sampleTrade];
    component.dateFrom = '2026-04-01';
    component.dateTo = '2026-07-01';
    component.timeframeId = 6;
    component.signalIndicatorIds = [1];
    component.ngOnChanges({
      trades: {
        currentValue: component.trades,
        previousValue: null,
        firstChange: true,
        isFirstChange: () => true,
      },
      signalIndicatorIds: {
        currentValue: component.signalIndicatorIds,
        previousValue: null,
        firstChange: true,
        isFirstChange: () => true,
      },
    });
    fixture.detectChanges();
  });

  it('lists only papers with trades', () => {
    expect(component.paperRows.length).toBe(1);
    expect(component.paperRows[0].security_id).toBe(7);
  });

  it('loads prices only after paper expand (lazy, no UI block on list)', () => {
    expect(api.getPrices).not.toHaveBeenCalled();
    component.togglePaper(new Event('click'), 7);
    expect(api.getPrices).toHaveBeenCalled();
    expect(api.syncIndicatorSeries).not.toHaveBeenCalled();
    expect(component.isPaperExpanded(7)).toBeTrue();
  });

  it('falls back to trade timeframe_id when input timeframeId is null', () => {
    component.timeframeId = null;
    component.togglePaper(new Event('click'), 7);
    expect(api.getPrices).toHaveBeenCalledWith(7, 6, 200, jasmine.any(String));
  });

  it('chartIndicatorsForDisplay returns EMPTY while suppressIndicators', () => {
    const st = component.chartState(7);
    st.suppressIndicators = true;
    st.indicatorSeries = [
      {
        indicator_code: 'SMA',
        line_code: 'VALUE',
        line_name: 'SMA',
        color: '#000',
        on_price_scale: true,
        is_threshold: false,
        points: [],
      },
    ];
    expect(component.chartIndicatorsForDisplay(7)).toEqual([]);
  });

  it('onVisibleRange auto emit does not suppress', () => {
    const st = component.chartState(7);
    st.candles = [
      {
        dt: '2026-04-10 10:00:00',
        open_price: 1,
        high_price: 1,
        low_price: 1,
        close_price: 1,
        volume: 1,
      },
    ];
    component.onVisibleRange(7, {
      startDt: '2026-04-10 10:00:00',
      endDt: '2026-04-10 10:00:00',
      count: 1,
      viewStart: 0,
      userInitiated: false,
    });
    expect(st.suppressIndicators).toBeFalse();
    expect(api.getIndicatorValues).toHaveBeenCalled();
    expect(api.syncIndicatorSeries).not.toHaveBeenCalled();
  });

  it('caches overlays so expand does not rebuild markers each read', () => {
    const a = component.overlays(7);
    const b = component.overlays(7);
    expect(a).toBe(b);
    expect(a.markers.length).toBeGreaterThan(0);
  });
});
