import React, { useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { KeystrokeData, Location } from '../types';
import { supabase } from '../lib/supabase';
import { LogIn } from 'lucide-react';
import { debounce } from '../utils/debounce';

const DEBOUNCE_DELAY = 1000;

export default function LoginPage() {
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [location, setLocation] = useState<Location | null>(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [keystrokes, setKeystrokes] = useState<KeystrokeData[]>([]);
  const [startTime] = useState(Date.now());

  const getLocation = useCallback(() => {
    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        (position) => {
          setLocation({
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
          });
        },
        (error) => {
          console.error('Location error:', error);
        }
      );
    }
  }, []);

  React.useEffect(() => {
    getLocation();
  }, [getLocation]);

  const debouncedLogin = useCallback(
    debounce(async (email: string, password: string, keystrokes: KeystrokeData[]) => {
      try {
        setLoading(true);
        setError('');

        // Authenticate with Supabase
        const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
          email,
          password,
        });

        if (authError) {
          throw new Error(authError.message.includes('Invalid login credentials')
            ? 'Invalid email or password'
            : authError.message);
        }

        if (!authData.user) {
          throw new Error('Authentication failed');
        }

        // Create keystroke session
        const { data: sessionData, error: sessionError } = await supabase
          .from('keystroke_sessions')
          .insert({
            user_id: authData.user.id,
            test_text: password,
            completed: true,
          })
          .select()
          .single();

        if (sessionError) {
          throw new Error('Failed to create session');
        }

        // Insert keystroke data
        const { error: keystrokeError } = await supabase
          .from('keystroke_data')
          .insert(
            keystrokes.map((stroke) => ({
              session_id: sessionData.id,
              key_pressed: stroke.key,
              press_time: stroke.press_time,
              release_time: stroke.release_time,
              dwell_time: stroke.release_time - stroke.press_time,
              flight_time: null,
            }))
          );

        if (keystrokeError) {
          throw new Error('Failed to save keystroke data');
        }

        // Verify keystroke pattern
        const { data: verificationData, error: verificationError } = await supabase
          .rpc('verify_keystroke_pattern', {
            user_id: authData.user.id,
            session_id: sessionData.id,
          });

        if (verificationError) {
          throw new Error('Failed to verify keystroke pattern');
        }

        const matchScore = verificationData.match_score;

        // Record authentication attempt
        const { error: attemptError } = await supabase
          .from('auth_attempts')
          .insert({
            user_id: authData.user.id,
            success: true,
            keystroke_match: matchScore >= 0.7,
            location_match: true, // Simplified
            attempted_at: new Date().toISOString(),
          });

        if (attemptError) {
          console.error('Auth attempt error:', attemptError);
        }

        // Navigate based on verification result
        if (matchScore >= 0.7) {
          setKeystrokes([]); // Reset keystrokes
          navigate('/dashboard');
        } else {
          navigate('/otp');
        }
      } catch (err: any) {
        const message = err instanceof Error ? err.message : 'An unexpected error occurred';
        console.error('Login error:', message);
        setError(message);
      } finally {
        setLoading(false);
      }
    }, DEBOUNCE_DELAY),
    [navigate]
  );

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    const pressTime = Date.now() - startTime;
    setKeystrokes((prev) => [
      ...prev,
      { key: e.key, press_time: pressTime, release_time: 0 },
    ]);
  };

  const handleKeyUp = (e: React.KeyboardEvent<HTMLInputElement>) => {
    const releaseTime = Date.now() - startTime;
    setKeystrokes((prev) =>
      prev.map((stroke) =>
        stroke.key === e.key && stroke.release_time === 0
          ? { ...stroke, release_time: releaseTime }
          : stroke
      )
    );
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (loading) return;

    if (!email.trim() || !password.trim()) {
      setError('Please enter both email and password');
      return;
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      setError('Please enter a valid email address');
      return;
    }

    if (password.length < 6) {
      setError('Password must be at least 6 characters long');
      return;
    }

    if (keystrokes.some((stroke) => stroke.release_time === 0)) {
      setError('Please complete typing your password before submitting');
      return;
    }

    debouncedLogin(email, password, keystrokes);
  };

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col items-center justify-center p-4">
      <div className="w-full max-w-md bg-white rounded-lg shadow-lg p-8">
        <div className="flex justify-center mb-8">
          <LogIn className="w-16 h-16 text-blue-500" />
        </div>
        <h1 className="text-2xl font-bold text-center mb-8">Sign In</h1>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Email</label>
            <input
              type="email"
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
              value={email}
              onChange={(e) => {
                setEmail(e.target.value);
                setError('');
              }}
              disabled={loading}
              required
              placeholder="your@email.com"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700">Password</label>
            <input
              type="password"
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
              value={password}
              onChange={(e) => {
                setPassword(e.target.value);
                setError('');
              }}
              onKeyDown={handleKeyDown}
              onKeyUp={handleKeyUp}
              disabled={loading}
              required
              autoComplete="current-password"
              placeholder="••••••"
            />
          </div>
          <button
            type="submit"
            className="w-full bg-blue-500 text-white rounded-md py-2 hover:bg-blue-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            disabled={loading}
          >
            {loading ? (
              <div className="flex items-center justify-center">
                <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-white"></div>
                <span className="ml-2">Signing in...</span>
              </div>
            ) : (
              'Sign In'
            )}
          </button>
        </form>

        {error && (
          <div className="mt-4 p-3 bg-red-50 border border-red-200 rounded-md">
            <p className="text-sm text-red-600">{error}</p>
          </div>
        )}

        <p className="mt-4 text-center text-sm text-gray-600">
          Don't have an account?{' '}
          <a href="/signup" className="text-blue-500 hover:text-blue-600">
            Sign up
          </a>
        </p>
      </div>
    </div>
  );
}
