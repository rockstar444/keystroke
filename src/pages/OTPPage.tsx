import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Shield } from 'lucide-react';

export default function OTPPage() {
  const navigate = useNavigate();
  const [otp, setOtp] = useState('');
  const [error, setError] = useState('');

  const handleVerify = async () => {
    try {
      // TODO: Implement OTP verification with backend
      navigate('/dashboard');
    } catch (error) {
      setError('Invalid OTP. Please try again.');
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 flex flex-col items-center justify-center p-4">
      <div className="w-full max-w-md bg-white rounded-lg shadow-lg p-8">
        <div className="flex justify-center mb-8">
          <Shield className="w-16 h-16 text-blue-500" />
        </div>
        <h1 className="text-2xl font-bold text-center mb-8">Enter OTP</h1>

        <div className="space-y-4">
          <p className="text-sm text-gray-600 text-center">
            We've sent a verification code to your email address.
          </p>
          <div>
            <label className="block text-sm font-medium text-gray-700">OTP Code</label>
            <input
              type="text"
              className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
              value={otp}
              onChange={(e) => setOtp(e.target.value)}
              maxLength={6}
            />
          </div>
          <button
            className="w-full bg-blue-500 text-white rounded-md py-2 hover:bg-blue-600 transition-colors"
            onClick={handleVerify}
          >
            Verify
          </button>
        </div>

        {error && (
          <p className="mt-4 text-red-500 text-center">{error}</p>
        )}
      </div>
    </div>
  );
}
