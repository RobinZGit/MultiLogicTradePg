import { ComponentFixture, TestBed, fakeAsync, tick } from '@angular/core/testing';
import { NO_ERRORS_SCHEMA } from '@angular/core';
import { of, delay } from 'rxjs';
import { SecuritiesPanelComponent } from './securities-panel.component';
import { SecuritiesService } from '../services/securities.service';
import { ReferencesService } from '../services/references.service';
import { AppConfigService } from '../services/app-config.service';
import { SettingsService } from '../services/settings.service';
import {
  SecurityIndicatorSeriesRow,
  SecurityRow,
} from '../models/market.model';

describe('SecuritiesPanelComponent', () => {
  let component: SecuritiesPanelComponent;
  let fixture: ComponentFixture<SecuritiesPanelComponent>;
  let securities: jasmine.SpyObj<SecuritiesService>;

  const sberRow: SecurityRow = {
    id: 29,
    name: 'SBER',
    security_type: 'Stock',
    prefix: 'SBER',
    instrument_market: 'stock',
    exchange_id: 1,
    exchange_name: 'MOEX',
  };

  const stochSeries: SecurityIndicatorSeriesRow[] = [
    {
      id: 1,
      security_id: 29,
      indicator_id: 7,
      series_code: 'K',
      invoke_formula: 'calc_ind_stoch_array(...)',
      indicator_code: 'STOCH',
      indicator_name: 'Stochastic',
      point_count: 100,
      display_order: 1,
      is_active: true,
    },
    {
      id: 2,
      security_id: 29,
      indicator_id: 7,
      series_code: 'D',
      invoke_formula: 'calc_ind_stoch_array(...)',
      indicator_code: 'STOCH',
      indicator_name: 'Stochastic',
      point_count: 100,
      display_order: 2,
      is_active: true,
    },
  ];

  beforeEach(async () => {
    securities = jasmine.createSpyObj('SecuritiesService', [
      'getTimeframes',
      'getSecurities',
      'getPrices',
      'getSecurityIndicatorSeries',
      'syncIndicatorSeries',
      'assignIndicatorSeries',
      'removeIndicatorSeries',
      'loadPrices',
      'getIndicatorValues',
    ]);
    securities.getTimeframes.and.returnValue(
      of([{ id: 6, tf: 'M15', full_name: '15 min', sec: 900, is_active: true }])
    );
    securities.getSecurities.and.returnValue(of([]));
    securities.getPrices.and.returnValue(of([]));
    securities.getSecurityIndicatorSeries.and.returnValue(of([]));
    securities.syncIndicatorSeries.and.returnValue(of({ ok: true }));
    securities.getIndicatorValues.and.returnValue(of([]));

    const refs = jasmine.createSpyObj('ReferencesService', [
      'getExchanges',
      'getIndicators',
    ]);
    refs.getExchanges.and.returnValue(
      of([{ id: 1, name: 'MOEX', is_active: true }])
    );
    refs.getIndicators.and.returnValue(of([]));

    const settings = jasmine.createSpyObj('SettingsService', [
      'getTbankTokenStatus',
      'saveTbankToken',
    ]);
    settings.getTbankTokenStatus.and.returnValue(of({ has_token: true }));

    await TestBed.configureTestingModule({
      imports: [SecuritiesPanelComponent],
      providers: [
        { provide: SecuritiesService, useValue: securities },
        { provide: ReferencesService, useValue: refs },
        { provide: SettingsService, useValue: settings },
        { provide: AppConfigService, useValue: { apiUrl: 'http://localhost:3000/api' } },
      ],
      schemas: [NO_ERRORS_SCHEMA],
    }).compileComponents();

    fixture = TestBed.createComponent(SecuritiesPanelComponent);
    component = fixture.componentInstance;
    component.timeframeId = 6;
    component.stocksExpanded = true;
    component.stocks = [sberRow];
  });

  it('shows empty-chart hint after expand when there are no prices', fakeAsync(() => {
    securities.getPrices.and.returnValue(of([]).pipe(delay(10)));
    securities.getSecurityIndicatorSeries.and.returnValue(
      of(stochSeries).pipe(delay(50))
    );

    component.toggleSecurity(sberRow);
    expect(component.isSecurityExpanded(29)).toBeTrue();
    expect(component.chartState(29).loading).toBeTrue();

    tick(10);
    fixture.detectChanges();

    expect(component.chartState(29).loading).toBeFalse();
    expect(component.chartState(29).candles.length).toBe(0);
    expect(component.chartState(29).error).toContain('Загрузить цены');

    tick(50);
    expect(securities.syncIndicatorSeries).not.toHaveBeenCalled();
    expect(component.isIndicatorsLoading(29)).toBeFalse();
  }));

  it('loads chart immediately without waiting for indicator series fetch', fakeAsync(() => {
    let pricesRequested = false;
    securities.getPrices.and.callFake(() => {
      pricesRequested = true;
      return of([]);
    });
    securities.getSecurityIndicatorSeries.and.returnValue(
      of(stochSeries).pipe(delay(200))
    );

    component.toggleSecurity(sberRow);
    tick(1);

    expect(pricesRequested).toBeTrue();
    expect(component.chartState(29).loading).toBeFalse();

    tick(200);
    expect(component.assignedIndicatorSeries(29).length).toBe(2);
    expect(securities.syncIndicatorSeries).not.toHaveBeenCalled();
  }));

  it('shows assigning status while indicator is being attached', () => {
    component.indicatorAssigning.add(29);
    expect(component.indicatorStatus(29)).toBe('Добавление индикатора…');
    expect(component.isIndicatorsLoading(29)).toBeFalse();
  });

  it('shows background recalc message in actions area', () => {
    component.indicatorRecalc.set(29, {
      active: true,
      message: 'Пересчёт PACC…',
      error: null,
    });
    expect(component.isIndicatorRecalcActive(29)).toBeTrue();
    expect(component.indicatorStatus(29)).toBe('Пересчёт PACC…');
  });

  it('does not block chart loading overlay on indicator sync', () => {
    component.charts.set(29, {
      candles: [{ dt: '2026-01-02T10:00:00', open_price: 1, high_price: 1, low_price: 1, close_price: 1, volume: 1 }],
      loading: false,
      loadingOlder: false,
      hasMore: false,
      error: null,
    });
    component.indicatorsLoading.add(29);

    expect(component.chartState(29).loading).toBeFalse();
    expect(component.isIndicatorsLoading(29)).toBeTrue();
  });

  it('formats series label with series code', () => {
    expect(component.seriesLabel(stochSeries[0])).toBe('STOCH K — Stochastic');
    expect(
      component.seriesLabel({
        ...stochSeries[0],
        series_code: 'VALUE',
        indicator_code: 'RSI',
        indicator_name: 'RSI',
      })
    ).toBe('RSI — RSI');
  });

  it('collapses security on second toggle', () => {
    component.toggleSecurity(sberRow);
    expect(component.isSecurityExpanded(29)).toBeTrue();
    component.toggleSecurity(sberRow);
    expect(component.isSecurityExpanded(29)).toBeFalse();
  });
});
