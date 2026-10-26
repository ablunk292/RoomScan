import { useState } from 'react';
import { supabase } from '../lib/supabase';

export default function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);

  const signIn = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setError(error.message);
    setBusy(false);
  };

  const withProvider = async (provider: 'google' | 'azure') => {
    setError('');
    const { error } = await supabase.auth.signInWithOAuth({
      provider,
      options: { redirectTo: window.location.href, scopes: provider === 'azure' ? 'email' : undefined },
    });
    if (error) setError(error.message);
  };

  const reset = async () => {
    if (!email) { setError('Enter your email first.'); return; }
    const { error } = await supabase.auth.resetPasswordForEmail(email);
    if (error) setError(error.message); else setSent(true);
  };

  return (
    <div className="login">
      <form className="card login-card" onSubmit={signIn}>
        <img src="/icon.svg" alt="" width={44} height={44} />
        <h1>RoomScan</h1>
        <p className="muted">Sign in with your QuoteMaster account to edit walkthroughs from the phone.</p>
        <button type="button" className="sso" onClick={() => withProvider('google')}>Continue with Google</button>
        <button type="button" className="sso" onClick={() => withProvider('azure')}>Continue with Microsoft</button>
        <div className="or muted small">or with email</div>
        <label>Email<input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label>Password<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {error && <div className="error">{error}</div>}
        {sent && <div className="ok">Check your email for a link to reset your password.</div>}
        <button className="primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign In'}</button>
        <button type="button" className="link" onClick={reset}>Forgot password?</button>
      </form>
    </div>
  );
}
