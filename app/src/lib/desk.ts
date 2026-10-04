'use client'

import { useMemo } from 'react'
import { FRIDAY_OBSERVATIONS, MONDAY_OBSERVATIONS } from './script'
import { useHistory, type HistoryItem } from './history'
import { WAD, type Anchor, type Policy, type StepState } from './scenario'
import { usePosition, useSession, type LocalReceipt } from './session'
import { useViewing } from './viewing'

export interface Obs {
  t: number // UTC seconds
  price: number
  day: 'fri' | 'mon'
}

/** A confirmed transaction placed on the session timeline. */
export interface Marker {
  t: number
  item: HistoryItem
  /** Signed while the testnet clock was elsewhere: placed at the scripted step it was signed in. */
  placed: boolean
}

/** The fixed chart observations at absolute times on the anchor's calendar. */
export function observations(a: Anchor): Obs[] {
  const fri = FRIDAY_OBSERVATIONS.map(([m, p]) => ({ t: Number(a.fri.open) + m * 60, price: p, day: 'fri' as const }))
  const mon = MONDAY_OBSERVATIONS.map(([m, p]) => ({ t: Number(a.mon.open) + m * 60, price: p, day: 'mon' as const }))
  return [...fri, ...mon]
}

/**
 * The liquidation threshold over the scripted session, from the contract reads: the Friday reopening limits until
 * credit returns, 80% until the ramp, the contract's ltAt values along the ramp, the weekend limit through the
 * closure and the Monday recovery, then 80% once credit returns.
 */
export function thresholdPath(a: Anchor, pol: Policy, steps: StepState[]): { t: number; lt: number }[] {
  const f = (w: bigint) => Number(w) / 1e18
  const friCredit = Number(a.fri.open) + 900
  const monCredit = Number(steps.find(s => s.step.id === 'admit')?.snapshot.creditAt ?? a.mon.open + 900n)
  // Friday's own reopening runs at the limits of the closure before it (SessionRiskPolicy.classOf: 24 hours or more is extended).
  const fridayOpening = a.fri.open - a.prev.close >= 86_400n ? pol.ltFinalExtended : pol.ltFinalOvernight
  return [
    { t: Number(a.fri.open), lt: f(fridayOpening) },
    { t: friCredit - 1, lt: f(fridayOpening) },
    { t: friCredit, lt: f(pol.ltOpen) },
    ...pol.ramp.map(r => ({ t: Number(r.t), lt: f(r.lt) })),
    { t: Number(a.fri.close), lt: f(pol.ltFinal) },
    { t: Number(a.mon.open), lt: f(pol.ltFinal) },
    { t: monCredit - 1, lt: f(pol.ltFinal) },
    { t: monCredit, lt: f(pol.ltOpen) },
    { t: Number(a.mon.open) + 1800, lt: f(pol.ltOpen) },
  ]
}

export function ltAtTime(path: { t: number; lt: number }[], t: number): number {
  let lt = path[0]?.lt ?? 0
  for (let i = 0; i < path.length; i++) {
    const p = path[i]
    if (p.t > t) {
      const q = path[i - 1]
      if (q && p.t - q.t <= 600 && p.t - q.t > 1) return q.lt + ((p.lt - q.lt) * (t - q.t)) / (p.t - q.t)
      return lt
    }
    lt = p.lt
  }
  return lt
}

/** Chart markers show what moved the position: debt or collateral changes, not plan funding or authorizations. */
const CHARTED = new Set(['Buffer repaid', 'Trimmed', 'Repaid', 'Repaid from buffer', 'Borrowed', 'Written off', 'Collateral added', 'Collateral withdrawn'])

function markersFrom(items: HistoryItem[], receipts: LocalReceipt[], a: Anchor, steps: StepState[]): Marker[] {
  const lo = Number(a.fri.open)
  const hi = Number(a.mon.close)
  const out: Marker[] = []
  for (const item of items) {
    if (!CHARTED.has(item.kind)) continue
    if (item.t >= lo && item.t <= hi) out.push({ t: item.t, item, placed: false })
    else {
      const r = receipts.find(x => x.hash.toLowerCase() === item.hash.toLowerCase())
      const st = r && steps.find(s => s.step.id === r.step)
      if (st) out.push({ t: Number(st.t), item, placed: true })
    }
  }
  return out.sort((x, y) => x.t - y.t)
}

/**
 * Everything the borrower pages show for the viewed account at the current step: the session, the contract-valued
 * position, the account's confirmed transactions, and those transactions placed on the scripted timeline.
 */
export function useDesk() {
  const session = useSession()
  const viewing = useViewing()
  const position = usePosition(viewing.viewing)
  const history = useHistory(viewing.viewing, position.data?.collateral)
  const items = useMemo(() => history.data?.items ?? [], [history.data])
  const { anchor, policy, steps, receipts, current } = session
  const obs = useMemo(() => (anchor ? observations(anchor) : []), [anchor])
  const ltPath = useMemo(() => (anchor && policy && steps ? thresholdPath(anchor, policy, steps) : []), [anchor, policy, steps])
  const markers = useMemo(() => (anchor && steps ? markersFrom(items, receipts, anchor, steps) : []), [items, receipts, anchor, steps])
  const now = current ? Number(current.t) : 0
  return { ...session, ...viewing, position: position.data, positionError: position.error, items, obs, ltPath, markers, now, historyError: history.error }
}

export const toFrac = (w: bigint | undefined) => (w === undefined ? undefined : Number(w) / Number(WAD))
