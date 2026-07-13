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
  commission: number;
  financial_result: number | null;
  remaining_qty?: number | null;
  note: string | null;
  created_at?: string;
  security_name: string;
  security_prefix: string | null;
  side_name: string;
  action_name: string;
  timeframe_tf: string;
}

export interface LogicTradeLotRow {
  id: number;
  logic_id: number;
  close_trade_id: number;
  open_trade_id: number | null;
  action_id: number;
  cost_method: 'FIFO' | 'AVERAGE';
  quantity: number;
  close_amount: number;
  open_amount: number;
  close_commission: number;
  open_commission: number;
  financial_result: number;
  created_at?: string;
  action_name: string;
  open_executed_at: string | null;
  open_price: number | null;
  close_executed_at: string;
  close_price: number;
}

export interface ClosedPositionGroup {
  id: number;
  close: LogicTradeRow;
  opens: LogicTradeRow[];
  pnl: number;
}

export function costMethodLabel(method: string): string {
  switch (method?.toUpperCase()) {
    case 'FIFO':
      return 'FIFO';
    case 'AVERAGE':
      return 'Средняя';
    default:
      return method;
  }
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
