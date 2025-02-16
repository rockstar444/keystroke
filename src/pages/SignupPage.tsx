import React, { useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { KeystrokeData, Location } from '../types';
import KeystrokeInput from '../components/KeystrokeInput';
import { supabase } from '../lib/supabase';
import { UserCircle } from 'lucide-react';
import { debounce } from '../utils/debounce';

const TYPING_TEST = "The quick brown fox jumps over the lazy dog";
const DEBOUNCE_DELAY = 1000; // 1 second delay between requests

export default function SignupPage() {
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [location, setLocation] = useState<Location | null>(null);
  const [step, setStep] = useState(1);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const getLocation = () => {
    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        (position) => {
          setLocation({
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
          });
        },
        (error) => {
          setError('Location access denied. Please enable location services.');
        }
      );
    } else {
      setError('Geolocation is not supported by your browser.');
    }
  };

  // Check if email exists before proceeding
  const checkEmailExists = async (email: string) => {
    try {
      const { count } = await supabase
        .from('profiles')
        .select('*', { count: 'exact', head: true })
        .eq('email', email);
      
      return count ? count > 0 : false;
    } catch (error) {
      console.error('Error checking email:', error);
      return false;
    }
  };

  const debouncedSignup = useCallback(
    debounce(async (email: string, password: string, keystrokes: KeystrokeData[]) => {
      try {
        setLoading(true);
        setError('');

        // Check if email exists first
        const emailExists = await checkEmailExists(email);
        if (emailExists) {
          setError('This email is already registered. Please use a different email or sign in.');
          setLoading(false);
          return;
        }

        // 1. Create auth user
        const { data: authData, error: authError } = await supabase.auth.signUp({
          email,
          password,
          options: {
            emailRedirectTo: window.location.origin + '/login',
          }
        });

        if (authError) {
          if (authError.status === 429) {
            setError('Too many attempts. Please wait a moment before trying again.');
            return;
          }
          if (authError.status === 422) {
            setError('This email is already registered. Please use a different email or sign in.');
            return;
          }
          if (authError.status === 500) {
            setError('Server error. Please try again in a few minutes.');
            return;
          }
          throw authError;
        }

        if (!authData.user) {
          throw new Error('No user data returned');
        }

        // 2. Create profile
        const { error: profileError } = await supabase
          .from('profiles')
          .insert({
            id: authData.user.id,
            email,
            location_lat: location?.latitude,
            location_lng: location?.longitude,
          });

        if (profileError) {
          if (profileError.code === '23505') { // Unique constraint violation
            setError('This email is already registered. Please use a different email or sign in.');
            return;
          }
          throw profileError;
        }

        // 3. Create keystroke session
        const { data: sessionData, error: sessionError } = await supabase
          .from('keystroke_sessions')
          .insert({
            user_id: authData.user.id,
            test_text: TYPING_TEST,
            completed: true,
          })
          .select()
          .single();

        if (sessionError) throw sessionError;

        // 4. Insert keystroke data
        const keystrokeData = keystrokes.map(stroke => ({
          session_id: sessionData.id,
          key_pressed: stroke.key,
          press_time: stroke.press_time,
          release_time: stroke.release_time,
        }));

        const { error: keystrokeError } = await supabase
          .from('keystroke_data')
          .insert(keystrokeData);

        if (keystrokeError) throw keystrokeError;

        // Success - navigate to login
        setError('');
        navigate('/login', { 
          state: { 
            message: 'Account created successfully! Please sign in.' 
          }
        });
      } catch (error: any) {
        console.error('Signup error:', error);
        if (error.message?.includes('rate limit')) {
          setError('Too many attempts. Please wait a moment before trying again.');
        } else {
          setError(error.message || 'An error occurred during signup. Please try again.');
        }
      } finally {
        setLoading(false);
      }
    }, DEBOUNCE_DELAY),
    [location, navigate]
  );

  const handleSignup = (keystrokes: KeystrokeData[]) => {
    if (loading) return;
    debouncedSignup(email, password, keystrokes);
  };

  const validateEmail = (email: string) => {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    return emailRegex.test(email);
  };

  const validatePassword = (password: string) => {
    return password.length >= 6;
  };

  const canProceed = validateEmail(email) && validatePassword(password);

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col items-center justify-center p-4">
      <div className="w-full max-w-md bg-white rounded-lg shadow-lg p-8">
        <div className="flex justify-center mb-8">
          <UserCircle className="w-16 h-16 text-blue-500" />
        </div>
        <h1 className="text-2xl font-bold text-center mb-8">Create Account</h1>

        {step === 1 && (
          <div className="space-y-4">
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
                placeholder="your@email.com"
              />
              {email && !validateEmail(email) && (
                <p className="mt-1 text-sm text-red-500">Please enter a valid email address</p>
              )}
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
                disabled={loading}
                placeholder="••••••"
              />
              {password && !validatePassword(password) && (
                <p className="mt-1 text-sm text-red-500">Password must be at least 6 characters</p>
              )}
            </div>
            <button
              className="w-full bg-blue-500 text-white rounded-md py-2 hover:bg-blue-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              onClick={() => {
                getLocation();
                setStep(2);
              }}
              disabled={loading || !canProceed}
            >
              Next
            </button>
          </div>
        )}

        {step === 2 && (
          <div className="space-y-4">
            <h2 className="text-lg font-medium text-center mb-4">Typing Test</h2>
            <p className="text-sm text-gray-600 mb-4">
              Please type the following sentence to complete your registration:
            </p>
            <KeystrokeInput text={TYPING_TEST} onComplete={handleSignup} />
            {loading && (
              <div className="flex justify-center">
                <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-blue-500"></div>
              </div>
            )}
          </div>
        )}

        {error && (
          <div className="mt-4 p-3 bg-red-50 border border-red-200 rounded-md">
            <p className="text-sm text-red-600">{error}</p>
          </div>
        )}

        <p className="mt-4 text-center text-sm text-gray-600">
          Already have an account?{' '}
          <a href="/login" className="text-blue-500 hover:text-blue-600">
            Sign in
          </a>
        </p>
      </div>
    </div>
  );
}
