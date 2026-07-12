export type LogicStopRuleKind = 'stop_loss' | 'take_profit';
export type LogicStopScopeType = 'logic' | 'portfolio';
export type LogicStopValueUnit = 'percent' | 'atr';

export function ruleKindLabel(kind: LogicStopRuleKind): string {
  return kind === 'stop_loss' ? 'Стоп-лосс' : 'Тейк-профит';
}

export function scopeTypeLabel(scope: LogicStopScopeType): string {
  return scope === 'logic' ? 'По логике' : 'Портфель логики';
}

export function valueUnitLabel(unit: LogicStopValueUnit): string {
  return unit === 'percent' ? '%' : 'ATR';
}

export const LOGIC_STOP_SCOPES: LogicStopScopeType[] = ['logic', 'portfolio'];
export const LOGIC_STOP_UNITS: LogicStopValueUnit[] = ['percent', 'atr'];
