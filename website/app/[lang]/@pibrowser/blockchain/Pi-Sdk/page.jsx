import { getAllChainSnapshots } from './lib/piSDK.js';
import { getBlockchainDictionary, getCachedSnapshot, cacheSnapshot } from './database/db.js';

export default async function BlockchainPage({ params }) {
  const { lang } = await params;
  const dict = await getBlockchainDictionary(lang);

  const chainIds = ['pi', 'solana', 'ethereum'];
  const cached = await Promise.all(chainIds.map((id) => getCachedSnapshot(id)));
  const needsFetch = cached.some((c) => c === null);

  const snapshots = needsFetch ? await getAllChainSnapshots() : Object.fromEntries(
    chainIds.map((id, i) => [id, cached[i]])
  );

  if (needsFetch) {
    await Promise.all(chainIds.map((id) => cacheSnapshot(id, snapshots[id])));
  }

  return (
    <main className="blockchain-page">
      <label htmlFor="chain-select">{dict['chain.select']}</label>
      <select id="chain-select" defaultValue="pi">
        {chainIds.map((id) => (
          <option key={id} value={id}>{id}</option>
        ))}
      </select>

      {chainIds.map((id) => {
        const snap = snapshots[id];
        return (
          <article key={id} className="chain-card" data-chain={id}>
            <h2>{id}</h2>
            {snap?.error ? (
              <p className="status-error">{dict['status.unavailable']}</p>
            ) : id === 'pi' ? (
              <>
                <p>{dict['ledger.latest']}: {snap?.ledger?.sequence ?? '—'}</p>
                <h3>{dict['contracts.recent']}</h3>
                <ul>
                  {(snap?.contracts ?? []).slice(0, 5).map((ev, i) => (
                    <li key={i}>{ev.type} · {ev.contractId}</li>
                  ))}
                </ul>
              </>
            ) : (
              <p>{dict['block.latest']}: {snap?.slot ?? snap?.blockNumber ?? '—'}</p>
            )}
          </article>
        );
      })}
    </main>
  );
}
