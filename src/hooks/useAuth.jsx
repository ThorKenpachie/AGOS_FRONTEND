import { createContext, useContext, useState, useEffect, useRef } from 'react';
import { supabase } from '../lib/supabaseClient';
import { logger } from '../lib/logger';

const AuthContext = createContext(null);

// Max attempts + delay for the transient-race retry in fetchProfile below.
const PROFILE_FETCH_RETRIES = 3;
const PROFILE_FETCH_RETRY_DELAY_MS = 400;

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  // Bumped on every auth event so a slow/retrying fetchProfile call from an
  // earlier event can tell it's been superseded and drop its result instead
  // of writing stale state (see SignupPage.jsx: signUp() immediately fires
  // SIGNED_IN, before the profile row for that new user exists yet, and
  // the page signs back out moments later -- without this guard, a retry
  // that finally succeeds AFTER that sign-out would re-set `user` even
  // though the session is gone).
  const authGenRef = useRef(0);

  const clearError = () => setError('');

  useEffect(() => {

    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      authGenRef.current += 1;
      const gen = authGenRef.current;
      if (session) fetchProfile(session.user.id, gen);
      else {
        setUser(null);
        setLoading(false);
      }
    });

    return () => listener.subscription.unsubscribe();
  }, []);

  const fetchProfile = async (userId, gen, attempt = 0) => {
    const { data, error } = await supabase
      .from('profiles')
      .select('*, roles(role_desc)')
      .eq('id', userId)
      .single();

    if (gen !== authGenRef.current) return; // superseded by a newer auth event -- drop this result

    if (data) {
      setUser(data);
      setLoading(false);
      return;
    }

    // PGRST116 = "no rows returned". Expected transiently right after
    // self-signup: signUp() fires SIGNED_IN (email auto-confirm is on)
    // before SignupPage.jsx's own profile insert -- which needs the new
    // user's id from signUp()'s response -- has had a chance to run. Give
    // it a few short retries before treating it as a real failure.
    if (error?.code === 'PGRST116' && attempt < PROFILE_FETCH_RETRIES) {
      setTimeout(() => fetchProfile(userId, gen, attempt + 1), PROFILE_FETCH_RETRY_DELAY_MS);
      return;
    }

    logger.error('Profile fetch failed:', error?.message);
    setUser(null); // or handle as needed
    setLoading(false);
  };

  const login = async (username, password) => {
    setError('');
    const email = `${username}@agos.local`;
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) { setError('Invalid username or password.'); return false; }
    return true;
  };

  const createUser = async (payload) => {
  setError('');

  const { data: { session } } = await supabase.auth.getSession();

  if (!session) {
    setError("Not authenticated");
    return false;
  }

  const { data, error } = await supabase.functions.invoke('create-user', {
    body: payload,
    headers: {
      Authorization: `Bearer ${session.access_token}`,
    }
  });

  if (error) {
    const errorText = await error.context.text();
    logger.debug('FUNCTION ERROR BODY:', errorText);
    let message = 'Something went wrong';
    try {
      message = JSON.parse(errorText).error || message;
    } catch {
      // Edge function returned a non-JSON body (e.g. an HTML error page) --
      // fall back to the raw text instead of throwing here and leaving
      // setError() never called.
      if (errorText) message = errorText;
    }
    setError(message);
    return false;
  }

  return true;
};

  const logout = async () => {
    await supabase.auth.signOut();
    setUser(null);
  };
  
  return (
    <AuthContext.Provider value={{
      user,
      login,
      createUser,
      logout,
      clearError,
      error,
      loading
    }}>
      {children}
    </AuthContext.Provider>
  );
}

export const useAuth = () => useContext(AuthContext);