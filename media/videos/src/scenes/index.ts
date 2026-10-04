import type React from 'react';
import type {SceneProps} from '../theme';
import {Q1, Q10, Q11, Q12, Q2, Q3, Q4, Q5, Q6, Q7, Q8, Q9} from './pitch';

/** The pitch visual for each answer, by segment id in pitch.json. */
export const SCENES: Record<string, React.FC<SceneProps>> = {q1: Q1, q2: Q2, q3: Q3, q4: Q4, q5: Q5, q6: Q6, q7: Q7, q8: Q8, q9: Q9, q10: Q10, q11: Q11, q12: Q12};

