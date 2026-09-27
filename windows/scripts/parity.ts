// Dev helper: prints parity of the TS port vs. the Mac outputs. `npx vite-node scripts/parity.ts` or via vitest.
import golden from '../test/fixtures/mac-golden.json';
import * as QP from '../src/core/quickPolish';
import { targetForBundle, type Target } from '../src/core/smartLists';

const norm = (s: string) => s.replace(/[ \t]+/g, ' ').trim();
export function parity(verbose = false) {
  let pOk = 0, pN = 0, lOk = 0, lN = 0;
  const fails: string[] = [];
  for (const c of golden.polish) {
    if (c.screen) continue;
    pN++;
    const out = norm(QP.apply(c.input, targetForBundle(c.app)).text);
    if (out === norm(c.mac)) pOk++; else fails.push(`P ${c.id}: ${c.input}\n   mac: ${c.mac.replace(/\n/g, '⏎')}\n   ts : ${out.replace(/\n/g, '⏎')}`);
  }
  for (const c of golden.lists) {
    for (const [tg, mac] of Object.entries(c.mac as Record<string, string>)) {
      lN++;
      const out = norm(QP.apply(c.input, tg as Target).text);
      if (out === norm(mac)) lOk++; else fails.push(`L ${c.id} ${tg}: ${c.input}\n   mac: ${mac.replace(/\n/g, '⏎')}\n   ts : ${out.replace(/\n/g, '⏎')}`);
    }
  }
  if (verbose) console.log(fails.join('\n'));
  console.log(`polish ${pOk}/${pN}  lists ${lOk}/${lN}`);
  return { pOk, pN, lOk, lN, fails };
}
