export interface LogicRow {
  id: number;
  name: string;
  account_id: number;
  broker_id: number;
  is_enabled: boolean;
  account_code: string;
  account_name: string;
  account_type: 'real' | 'fake';
  account_is_active: boolean;
  broker_code: string;
  broker_name: string;
}

export interface LogicIndicatorSignalRow {
  id: number;
  logic_id: number;
  indicator_id: number;
  signal_kind: 'trend' | 'counter';
  formula: string;
  display_order: number;
  is_active: boolean;
  indicator_code: string;
  indicator_name: string;
}
