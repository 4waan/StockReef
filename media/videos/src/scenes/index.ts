import type React from 'react';
import type {SceneProps} from '../theme';
import {D1, D10, D11, D12, D13, D14, D15, D16, D2, D3, D4, D5, D6, D7, D8, D9} from './demo';
import {Q1, Q10, Q11, Q12, Q2, Q3, Q4, Q5, Q6, Q7, Q8, Q9} from './pitch';

/** The pitch visual for each answer, by segment id in pitch.json. */
export const SCENES: Record<string, React.FC<SceneProps>> = {q1: Q1, q2: Q2, q3: Q3, q4: Q4, q5: Q5, q6: Q6, q7: Q7, q8: Q8, q9: Q9, q10: Q10, q11: Q11, q12: Q12};

/** The demo visual for each answer, by segment id in demo.json. */
export const DEMO_SCENES: Record<string, React.FC<SceneProps>> = {d1: D1, d2: D2, d3: D3, d4: D4, d5: D5, d6: D6, d7: D7, d8: D8, d9: D9, d10: D10, d11: D11, d12: D12, d13: D13, d14: D14, d15: D15, d16: D16};
