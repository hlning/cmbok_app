/// 内置 z-library 账号（硬编码，对应 cmbook service/builtin_accounts.py）。
/// 轮询使用：搜索/下载时依次尝试登录，取首个可用账号。
/// 注意：含真实凭据，若仓库公开请加入 .gitignore（同 cmbook 做法）。
class BuiltinAccount {
  final String email;
  final String password;
  const BuiltinAccount({required this.email, required this.password});
}

const List<BuiltinAccount> kBuiltinAccounts = [
  BuiltinAccount(email: '1911607739@qq.com', password: 'chnattDJ'),
  BuiltinAccount(email: '19201347003@163.com', password: 'roMrzP6w'),
  BuiltinAccount(email: '3923258126@qq.com', password: 'ExpZF37s'),
  BuiltinAccount(email: 't28505858@gmail.com', password: 'kb6zfmnl'),
  BuiltinAccount(email: 'jerry051120@gmail.com', password: 'hWkrYvnN'),
  BuiltinAccount(email: 'miya011112@gmail.com', password: 'jbcT6dCe'),
  BuiltinAccount(email: 'c7735942@gmail.com', password: 'UzmehY6d'),
  BuiltinAccount(email: 'nhl684561@163.com', password: 'e5gSqusZ'),
];
