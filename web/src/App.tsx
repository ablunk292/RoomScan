import { useEffect, useState } from 'react';
import { Link, Route, Routes } from 'react-router-dom';
import type { Session } from '@supabase/supabase-js';
import { supabase, clearTenantCache, currentTenantId } from './lib/supabase';
import Login from './pages/Login';
import Walkthroughs from './pages/Walkthroughs';
import Walkthrough from './pages/Walkthrough';

export default function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const [hasCompany, setHasCompany] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_event, s) => {
      clearTenantCache();
      setSession(s);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (session) currentTenantId().then((id) => setHasCompany(!!id));
  }, [session]);

  if (session === undefined) return <div className="center muted">Loading…</div>;
  if (!session) return <Login />;

  return (
    <div className="app">
      <header className="topbar">
        <Link to="/" className="brand">
          <img src="/icon.svg" alt="" width={24} height={24} /> RoomScan
        </Link>
        <span className="spacer" />
        <span className="muted small">{session.user.email}</span>
        <button className="ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
      </header>
      {!hasCompany && (
        <div className="banner warn">
          Your account isn't part of a company in QuoteMaster yet. Finish setting it up in QuoteMaster, then reload.
        </div>
      )}
      <Routes>
        <Route path="/" element={<Walkthroughs />} />
        <Route path="/w/:id/*" element={<Walkthrough />} />
        <Route path="*" element={<Walkthroughs />} />
      </Routes>
    </div>
  );
}
