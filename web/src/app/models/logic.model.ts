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
