export type LogicTradeStatus =
  | 'pending'
  | 'submitted'
  | 'filled'
  | 'rejected'
  | 'cancelled';

export interface LogicTradeRow {
  id: number;
  logic_id: number;
  account_id: number;
  security_id: number;
  timeframe_id: number;
  side_id: number;
  action_id: number;
  signal_kind: 'trend' | 'counter';
  signal_formula: string;
  quantity: number;
  price: number;
  bar_dt: string;
  executed_at: string;
  is_simulated: boolean;
  is_fictitious: boolean;
  broker_order_id: string | null;
  status: LogicTradeStatus;
  note: string | null;
  created_at?: string;
  security_name: string;
  security_prefix: string | null;
  side_name: string;
  action_name: string;
  timeframe_tf: string;
}

export function tradeStatusLabel(status: LogicTradeStatus): string {
  switch (status) {
    case 'pending':
      return 'Ожидание';
    case 'submitted':
      return 'Отправлена';
    case 'filled':
      return 'Исполнена';
    case 'rejected':
      return 'Отклонена';
    case 'cancelled':
      return 'Отменена';
    default:
      return status;
  }
}

export function yesNoLabel(value: boolean): string {
  return value ? 'да' : 'нет';
}
