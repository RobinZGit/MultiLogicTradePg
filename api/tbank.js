const crypto = require('node:crypto');

function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

function moneyToNumber(money) {
  if (!money) return null;
  const units = Number(money.units ?? 0);
  const nano = Number(money.nano ?? 0);
  return units + nano / 1e9;
}

function formatMoney(amount, currency = 'RUB') {
  if (amount == null || Number.isNaN(amount)) return null;
  return new Intl.NumberFormat('ru-RU', {
    style: 'currency',
    currency,
    maximumFractionDigits: 2,
  }).format(amount);
}

async function tbankPost(apiBase, path, token, body) {
  const base = (apiBase || 'https://invest-public-api.tinkoff.ru/rest').replace(/\/$/, '');
  const url = `${base}/${path}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body ?? {}),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data?.message || data?.error || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return data;
}

async function fetchTbankPortfolioBalance(apiUrl, token, accountId) {
  const data = await tbankPost(
    apiUrl,
    'tinkoff.public.invest.api.contract.v1.OperationsService/GetPortfolio',
    token,
    { accountId }
  );
  const total = data?.totalAmountPortfolio || data?.totalAmountShares;
  const amount = moneyToNumber(total);
  const currency = total?.currency || 'RUB';
  return {
    amount,
    currency,
    display: formatMoney(amount, currency),
  };
}

async function fetchTbankAccounts(apiUrl, token) {
  const data = await tbankPost(
    apiUrl,
    'tinkoff.public.invest.api.contract.v1.UsersService/GetAccounts',
    token,
    {}
  );
  return data?.accounts ?? [];
}

function mapTbankAccount(a) {
  return {
    id: a.id,
    name: a.name || '',
    type: a.type || '',
    status: a.status || '',
  };
}

function pickTbankAccount(accounts, preferredId) {
  const list = accounts ?? [];
  if (list.length === 0) {
    throw new Error('По токену не найдено ни одного счёта в T-Bank');
  }
  if (preferredId) {
    const found = list.find((a) => a.id === preferredId);
    if (found) return found;
  }
  const open = list.find((a) => a.status === 'ACCOUNT_STATUS_OPEN');
  return open || list[0];
}

async function resolveTbankAccountByToken(apiUrl, token, preferredAccountId) {
  const accounts = await fetchTbankAccounts(apiUrl, token);
  const picked = pickTbankAccount(accounts, preferredAccountId || null);
  return {
    accounts: accounts.map(mapTbankAccount),
    picked,
    accountId: picked.id,
    accountName: picked.name || '',
  };
}

module.exports = {
  hashToken,
  fetchTbankPortfolioBalance,
  fetchTbankAccounts,
  resolveTbankAccountByToken,
  pickTbankAccount,
  mapTbankAccount,
  formatMoney,
};
