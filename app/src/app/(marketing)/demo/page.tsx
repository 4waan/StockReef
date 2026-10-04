import { redirect } from 'next/navigation'

/** The guided demo now runs inside the app: the terminal with the session bar. */
export default function DemoPage() {
  redirect('/trade')
}
