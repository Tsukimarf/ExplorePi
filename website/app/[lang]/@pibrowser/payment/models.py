"""
SQLAlchemy models for the Pi blockchain explorer database schema.

Mirrors schema.sql / schema.JSON in this folder. Running this file directly
creates a local SQLite database (pi_explorer.db) for quick testing:

    pip install sqlalchemy
    python models.py
"""

from datetime import datetime, timezone

from sqlalchemy import (
    Column,
    BigInteger,
    Integer,
    SmallInteger,
    String,
    Text,
    Numeric,
    DateTime,
    ForeignKey,
    UniqueConstraint,
    Index,
    create_engine,
)
from sqlalchemy.orm import declarative_base, relationship, sessionmaker

Base = declarative_base()


def utcnow():
    return datetime.now(timezone.utc)


class Ledger(Base):
    __tablename__ = "ledgers"

    sequence = Column(BigInteger, primary_key=True)
    hash = Column(String(64), nullable=False, unique=True)
    prev_hash = Column(String(64))
    closed_at = Column(DateTime, nullable=False)
    tx_count = Column(Integer, nullable=False, default=0)

    transactions = relationship("Transaction", back_populates="ledger")


class Account(Base):
    __tablename__ = "accounts"

    account_id = Column(String(56), primary_key=True)
    sequence_number = Column(BigInteger, nullable=False, default=0)
    subentry_count = Column(Integer, nullable=False, default=0)
    created_at = Column(DateTime, nullable=False, default=utcnow)

    balances = relationship("Balance", back_populates="account")


class Transaction(Base):
    __tablename__ = "transactions"

    tx_hash = Column(String(64), primary_key=True)
    ledger_seq = Column(BigInteger, ForeignKey("ledgers.sequence"), nullable=False)
    source_account = Column(String(56), ForeignKey("accounts.account_id"), nullable=False)
    fee_paid = Column(Integer, nullable=False)
    memo = Column(Text)
    result_code = Column(String(32), nullable=False)

    ledger = relationship("Ledger", back_populates="transactions")
    operations = relationship("Operation", back_populates="transaction")
    payments = relationship("Payment", back_populates="transaction")

    __table_args__ = (
        Index("idx_transactions_ledger_seq", "ledger_seq"),
        Index("idx_transactions_source_account", "source_account"),
    )


class Operation(Base):
    __tablename__ = "operations"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    tx_hash = Column(String(64), ForeignKey("transactions.tx_hash"), nullable=False)
    source_account = Column(String(56), ForeignKey("accounts.account_id"), nullable=False)
    type = Column(String(32), nullable=False)
    details = Column(Text)  # JSON blob, stored as text for SQLite compatibility

    transaction = relationship("Transaction", back_populates="operations")

    __table_args__ = (
        Index("idx_operations_tx_hash", "tx_hash"),
        Index("idx_operations_source_account", "source_account"),
    )


class Asset(Base):
    __tablename__ = "assets"

    asset_code = Column(String(12), primary_key=True)
    issuer = Column(String(56))
    type = Column(String(16), nullable=False)


class Balance(Base):
    __tablename__ = "balances"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    account_id = Column(String(56), ForeignKey("accounts.account_id"), nullable=False)
    asset_code = Column(String(12), ForeignKey("assets.asset_code"), nullable=False)
    amount = Column(Numeric(20, 7), nullable=False, default=0)

    account = relationship("Account", back_populates="balances")

    __table_args__ = (
        UniqueConstraint("account_id", "asset_code", name="uix_balances_account_asset"),
        Index("idx_balances_account_id", "account_id"),
    )


class Payment(Base):
    """
    The "payment" subset of operations (type_i = 1 in Stellar/Pi Horizon),
    denormalized for fast lookups by from/to account. Field names match
    what explorer/payment.jsx reads off each Horizon payment record:
    from, to, amount, created_at, type_i.
    """

    __tablename__ = "payments"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    operation_id = Column(BigInteger, ForeignKey("operations.id"))
    tx_hash = Column(String(64), ForeignKey("transactions.tx_hash"), nullable=False)
    type_i = Column(SmallInteger, nullable=False, default=1)
    from_account = Column(String(56), ForeignKey("accounts.account_id"), nullable=False)
    to_account = Column(String(56), ForeignKey("accounts.account_id"), nullable=False)
    asset_type = Column(String(16), nullable=False, default="native")
    asset_code = Column(String(12), ForeignKey("assets.asset_code"))
    asset_issuer = Column(String(56))
    amount = Column(Numeric(20, 7), nullable=False)
    created_at = Column(DateTime, nullable=False, default=utcnow)

    transaction = relationship("Transaction", back_populates="payments")

    __table_args__ = (
        Index("idx_payments_from_account", "from_account"),
        Index("idx_payments_to_account", "to_account"),
        Index("idx_payments_created_at", "created_at"),
    )

    def to_dict(self):
        """Shape matching the fields payment.jsx destructures from Horizon records."""
        return {
            "id": self.id,
            "tx_hash": self.tx_hash,
            "type_i": self.type_i,
            "from": self.from_account,
            "to": self.to_account,
            "asset_type": self.asset_type,
            "asset_code": self.asset_code,
            "asset_issuer": self.asset_issuer,
            "amount": str(self.amount),
            "created_at": self.created_at.isoformat(),
        }


if __name__ == "__main__":
    engine = create_engine("sqlite:///pi_explorer.db", echo=True)
    Base.metadata.create_all(engine)

    Session = sessionmaker(bind=engine)
    session = Session()

    # Minimal smoke-test insert matching the sample data in schema.JSON
    if not session.get(Ledger, 1000042):
        session.add(Ledger(
            sequence=1000042,
            hash="9f1c2e8a4b7d3f0e5c6a1b2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60",
            prev_hash="8e0b1d7943a6c2e4f5d091827364a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5",
            closed_at=datetime(2026, 9, 14, 8, 15, 0, tzinfo=timezone.utc),
            tx_count=3,
        ))
        session.commit()

    print(f"Created pi_explorer.db with tables: {list(Base.metadata.tables.keys())}")
