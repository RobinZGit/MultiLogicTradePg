export type LogicStopRuleKind = 'stop_loss' | 'take_profit';
export type LogicStopScopeType = 'security' | 'portfolio';
export type LogicStopValueUnit = 'percent' | 'atr';

export function ruleKindLabel(kind: LogicStopRuleKind): string {
  return kind === 'stop_loss' ? 'Стоп-лосс' : 'Тейк-профит';
}

export function scopeTypeLabel(scope: LogicStopScopeType): string {
  return scope === 'security' ? 'По бумаге' : 'По всему портфелю логики';
}

export function valueUnitLabel(unit: LogicStopValueUnit): string {
  return unit === 'percent' ? '%' : 'ATR';
}

export const LOGIC_STOP_SCOPES: LogicStopScopeType[] = ['security', 'portfolio'];
export const LOGIC_STOP_UNITS: LogicStopValueUnit[] = ['percent', 'atr'];
