/**
 * Sequelize models for the Pi blockchain explorer database schema.
 * Mirrors schema.sql / schema.JSON / models.py in this folder.
 *
 * This is the data-layer counterpart to explorer/payment.jsx, which reads
 * payments live from Horizon (server.payments()) rather than a local DB.
 * If/when the explorer moves to a local index instead of hitting Horizon
 * directly, this model backs a `payments` table with the same shape:
 * from, to, amount, created_at, type_i.
 *
 * Usage:
 *   npm install sequelize pg pg-hstore
 *   const db = require('./models')(new Sequelize(process.env.DATABASE_URL))
 *   await db.sequelize.sync()
 */

const { DataTypes, Model } = require('sequelize')

module.exports = (sequelize) => {
  class Ledger extends Model {}
  Ledger.init({
    sequence: { type: DataTypes.BIGINT, primaryKey: true },
    hash: { type: DataTypes.CHAR(64), allowNull: false, unique: true },
    prev_hash: { type: DataTypes.CHAR(64) },
    closed_at: { type: DataTypes.DATE, allowNull: false },
    tx_count: { type: DataTypes.INTEGER, allowNull: false, defaultValue: 0 },
  }, { sequelize, modelName: 'Ledger', tableName: 'ledgers', timestamps: false })

  class Account extends Model {}
  Account.init({
    account_id: { type: DataTypes.STRING(56), primaryKey: true },
    sequence_number: { type: DataTypes.BIGINT, allowNull: false, defaultValue: 0 },
    subentry_count: { type: DataTypes.INTEGER, allowNull: false, defaultValue: 0 },
    created_at: { type: DataTypes.DATE, allowNull: false, defaultValue: DataTypes.NOW },
  }, { sequelize, modelName: 'Account', tableName: 'accounts', timestamps: false })

  class Transaction extends Model {}
  Transaction.init({
    tx_hash: { type: DataTypes.CHAR(64), primaryKey: true },
    ledger_seq: { type: DataTypes.BIGINT, allowNull: false },
    source_account: { type: DataTypes.STRING(56), allowNull: false },
    fee_paid: { type: DataTypes.INTEGER, allowNull: false },
    memo: { type: DataTypes.TEXT },
    result_code: { type: DataTypes.STRING(32), allowNull: false },
  }, { sequelize, modelName: 'Transaction', tableName: 'transactions', timestamps: false })

  class Operation extends Model {}
  Operation.init({
    id: { type: DataTypes.BIGINT, primaryKey: true, autoIncrement: true },
    tx_hash: { type: DataTypes.CHAR(64), allowNull: false },
    source_account: { type: DataTypes.STRING(56), allowNull: false },
    type: { type: DataTypes.STRING(32), allowNull: false },
    details: { type: DataTypes.JSONB },
  }, { sequelize, modelName: 'Operation', tableName: 'operations', timestamps: false })

  class Asset extends Model {}
  Asset.init({
    asset_code: { type: DataTypes.STRING(12), primaryKey: true },
    issuer: { type: DataTypes.STRING(56) },
    type: { type: DataTypes.STRING(16), allowNull: false },
  }, { sequelize, modelName: 'Asset', tableName: 'assets', timestamps: false })

  class Balance extends Model {}
  Balance.init({
    id: { type: DataTypes.BIGINT, primaryKey: true, autoIncrement: true },
    account_id: { type: DataTypes.STRING(56), allowNull: false },
    asset_code: { type: DataTypes.STRING(12), allowNull: false },
    amount: { type: DataTypes.DECIMAL(20, 7), allowNull: false, defaultValue: 0 },
  }, {
    sequelize,
    modelName: 'Balance',
    tableName: 'balances',
    timestamps: false,
    indexes: [{ unique: true, fields: ['account_id', 'asset_code'] }],
  })

  // Field names match what explorer/payment.jsx destructures off each
  // Horizon payment record: data.from, data.to, data.amount, data.created_at,
  // data.type_i (payments are filtered client-side with `type_i !== 1`).
  class Payment extends Model {}
  Payment.init({
    id: { type: DataTypes.BIGINT, primaryKey: true, autoIncrement: true },
    operation_id: { type: DataTypes.BIGINT },
    tx_hash: { type: DataTypes.CHAR(64), allowNull: false },
    type_i: { type: DataTypes.SMALLINT, allowNull: false, defaultValue: 1 },
    from_account: { type: DataTypes.STRING(56), allowNull: false, field: 'from_account' },
    to_account: { type: DataTypes.STRING(56), allowNull: false, field: 'to_account' },
    asset_type: { type: DataTypes.STRING(16), allowNull: false, defaultValue: 'native' },
    asset_code: { type: DataTypes.STRING(12) },
    asset_issuer: { type: DataTypes.STRING(56) },
    amount: { type: DataTypes.DECIMAL(20, 7), allowNull: false },
    created_at: { type: DataTypes.DATE, allowNull: false, defaultValue: DataTypes.NOW },
  }, {
    sequelize,
    modelName: 'Payment',
    tableName: 'payments',
    timestamps: false,
    indexes: [
      { fields: ['from_account'] },
      { fields: ['to_account'] },
      { fields: ['created_at'] },
    ],
  })

  // Associations
  Transaction.belongsTo(Ledger, { foreignKey: 'ledger_seq' })
  Ledger.hasMany(Transaction, { foreignKey: 'ledger_seq' })

  Transaction.belongsTo(Account, { foreignKey: 'source_account' })
  Operation.belongsTo(Transaction, { foreignKey: 'tx_hash' })
  Transaction.hasMany(Operation, { foreignKey: 'tx_hash' })

  Balance.belongsTo(Account, { foreignKey: 'account_id' })
  Balance.belongsTo(Asset, { foreignKey: 'asset_code' })

  Payment.belongsTo(Transaction, { foreignKey: 'tx_hash' })
  Payment.belongsTo(Account, { foreignKey: 'from_account', as: 'sender' })
  Payment.belongsTo(Account, { foreignKey: 'to_account', as: 'receiver' })
  Transaction.hasMany(Payment, { foreignKey: 'tx_hash' })

  // Shape matching what payment.jsx expects from a Horizon record, so a
  // local-DB-backed API route can return the same JSON the component
  // already knows how to render.
  Payment.prototype.toHorizonShape = function () {
    return {
      id: this.id,
      tx_hash: this.tx_hash,
      type_i: this.type_i,
      from: this.from_account,
      to: this.to_account,
      asset_type: this.asset_type,
      asset_code: this.asset_code,
      asset_issuer: this.asset_issuer,
      amount: this.amount,
      created_at: this.created_at,
    }
  }

  return { sequelize, Ledger, Account, Transaction, Operation, Asset, Balance, Payment }
}
