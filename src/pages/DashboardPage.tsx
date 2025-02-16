import React, { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { LogOut, Activity, Clock, Fingerprint, Shield } from 'lucide-react';
import { supabase } from '../lib/supabase';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  BarChart,
  Bar,
} from 'recharts';

interface KeystrokeMetrics {
  typingSpeed: number;
  avgDwellTime: number;
  avgFlightTime: number;
  successRate: number;
  recentAttempts: any[];
  dwellTimeDistribution: any[];
  performanceTrend: any[];
}

export default function DashboardPage() {
  const navigate = useNavigate();
  const [metrics, setMetrics] = useState<KeystrokeMetrics | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchKeystrokeMetrics();
  }, []);

  const fetchKeystrokeMetrics = async () => {
    try {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) {
        navigate('/login');
        return;
      }

      const { data: profile } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', user.id)
        .single();

      const { data: attempts } = await supabase
        .from('auth_attempts')
        .select('*')
        .eq('user_id', user.id)
        .order('attempted_at', { ascending: false })
        .limit(5);

      const { data: keystrokeData } = await supabase
        .from('keystroke_data')
        .select(`
          *,
          keystroke_sessions(*)
        `)
        .eq('keystroke_sessions.user_id', user.id);

      const metrics = processKeystrokeData(keystrokeData, profile, attempts);
      setMetrics(metrics);
      setLoading(false);
    } catch (error) {
      console.error('Error fetching metrics:', error);
      setLoading(false);
    }
  };

  const processKeystrokeData = (keystrokeData: any[], profile: any, attempts: any[]) => {
    return {
      typingSpeed: profile?.avg_typing_speed || 0,
      avgDwellTime: profile?.avg_dwell_time || 0,
      avgFlightTime: profile?.avg_flight_time || 0,
      successRate: profile?.success_rate || 0,
      recentAttempts: attempts || [],
      dwellTimeDistribution: calculateDwellTimeDistribution(keystrokeData || []),
      performanceTrend: calculatePerformanceTrend(keystrokeData || []),
    };
  };

  const calculateDwellTimeDistribution = (data: any[]) => {
    const distribution: { [key: string]: { count: number; total: number } } = {};
    
    data.forEach(entry => {
      const key = entry.key_pressed || 'unknown';
      if (!distribution[key]) {
        distribution[key] = { count: 0, total: 0 };
      }
      if (typeof entry.dwell_time === 'number' && !isNaN(entry.dwell_time)) {
        distribution[key].count++;
        distribution[key].total += entry.dwell_time;
      }
    });

    return Object.entries(distribution).map(([key, { count, total }]) => ({
      key,
      value: count > 0 ? Number((total / count).toFixed(2)) : 0,
    }));
  };

  const calculatePerformanceTrend = (data: any[]) => {
    const trendMap = new Map<string, { count: number; total: number }>();

    data.forEach(entry => {
      if (!entry.created_at || typeof entry.typing_speed !== 'number' || isNaN(entry.typing_speed)) {
        return;
      }

      const date = new Date(entry.created_at).toLocaleDateString();
      const current = trendMap.get(date) || { count: 0, total: 0 };
      
      trendMap.set(date, {
        count: current.count + 1,
        total: current.total + entry.typing_speed,
      });
    });

    return Array.from(trendMap.entries())
      .map(([date, { count, total }]) => ({
        date,
        speed: Number((total / count).toFixed(2)) || 0,
      }))
      .sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());
  };

  const handleLogout = async () => {
    await supabase.auth.signOut();
    navigate('/login');
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500"></div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      <nav className="bg-white shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between h-16">
            <div className="flex items-center">
              <Activity className="w-6 h-6 text-blue-500 mr-2" />
              <h1 className="text-xl font-semibold text-gray-900">Keystroke Analytics</h1>
            </div>
            <div className="flex items-center">
              <button
                onClick={handleLogout}
                className="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-blue-500 hover:bg-blue-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
              >
                <LogOut className="w-4 h-4 mr-2" />
                Sign Out
              </button>
            </div>
          </div>
        </div>
      </nav>

      <main className="max-w-7xl mx-auto py-6 sm:px-6 lg:px-8">
        {/* Overview Cards */}
        <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-4 mb-8">
          <div className="bg-white overflow-hidden shadow rounded-lg">
            <div className="p-5">
              <div className="flex items-center">
                <div className="flex-shrink-0">
                  <Activity className="h-6 w-6 text-gray-400" />
                </div>
                <div className="ml-5 w-0 flex-1">
                  <dl>
                    <dt className="text-sm font-medium text-gray-500 truncate">
                      Typing Speed
                    </dt>
                    <dd className="text-lg font-semibold text-gray-900">
                      {metrics?.typingSpeed.toFixed(1) || '0'} CPM
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white overflow-hidden shadow rounded-lg">
            <div className="p-5">
              <div className="flex items-center">
                <div className="flex-shrink-0">
                  <Clock className="h-6 w-6 text-gray-400" />
                </div>
                <div className="ml-5 w-0 flex-1">
                  <dl>
                    <dt className="text-sm font-medium text-gray-500 truncate">
                      Avg Dwell Time
                    </dt>
                    <dd className="text-lg font-semibold text-gray-900">
                      {metrics?.avgDwellTime.toFixed(2) || '0'}ms
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white overflow-hidden shadow rounded-lg">
            <div className="p-5">
              <div className="flex items-center">
                <div className="flex-shrink-0">
                  <Fingerprint className="h-6 w-6 text-gray-400" />
                </div>
                <div className="ml-5 w-0 flex-1">
                  <dl>
                    <dt className="text-sm font-medium text-gray-500 truncate">
                      Success Rate
                    </dt>
                    <dd className="text-lg font-semibold text-gray-900">
                      {((metrics?.successRate || 0) * 100).toFixed(1)}%
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white overflow-hidden shadow rounded-lg">
            <div className="p-5">
              <div className="flex items-center">
                <div className="flex-shrink-0">
                  <Shield className="h-6 w-6 text-gray-400" />
                </div>
                <div className="ml-5 w-0 flex-1">
                  <dl>
                    <dt className="text-sm font-medium text-gray-500 truncate">
                      Recent Authentications
                    </dt>
                    <dd className="text-lg font-semibold text-gray-900">
                      {metrics?.recentAttempts.length || 0}
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Charts */}
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          {/* Dwell Time Distribution */}
          <div className="bg-white shadow rounded-lg p-6">
            <h3 className="text-lg font-medium text-gray-900 mb-4">Dwell Time Distribution</h3>
            <div className="h-64">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={metrics?.dwellTimeDistribution || []}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="key" />
                  <YAxis />
                  <Tooltip formatter={(value: number) => value.toFixed(2) + 'ms'} />
                  <Bar dataKey="value" fill="#3B82F6" />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </div>

          {/* Performance Trend */}
          <div className="bg-white shadow rounded-lg p-6">
            <h3 className="text-lg font-medium text-gray-900 mb-4">Performance Trend</h3>
            <div className="h-64">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={metrics?.performanceTrend || []}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="date" />
                  <YAxis />
                  <Tooltip formatter={(value: number) => value.toFixed(2) + ' CPM'} />
                  <Line type="monotone" dataKey="speed" stroke="#3B82F6" />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>
        </div>

        {/* Recent Authentication Attempts */}
        <div className="mt-8">
          <div className="bg-white shadow rounded-lg">
            <div className="px-4 py-5 sm:p-6">
              <h3 className="text-lg font-medium text-gray-900 mb-4">Recent Authentication Attempts</h3>
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-gray-200">
                  <thead>
                    <tr>
                      <th className="px-6 py-3 bg-gray-50 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Date
                      </th>
                      <th className="px-6 py-3 bg-gray-50 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Status
                      </th>
                      <th className="px-6 py-3 bg-gray-50 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Keystroke Match
                      </th>
                      <th className="px-6 py-3 bg-gray-50 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                        Location Match
                      </th>
                    </tr>
                  </thead>
                  <tbody className="bg-white divide-y divide-gray-200">
                    {(metrics?.recentAttempts || []).map((attempt, index) => (
                      <tr key={index}>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                          {new Date(attempt.attempted_at).toLocaleString()}
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap">
                          <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${
                            attempt.success
                              ? 'bg-green-100 text-green-800'
                              : 'bg-red-100 text-red-800'
                          }`}>
                            {attempt.success ? 'Success' : 'Failed'}
                          </span>
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {attempt.keystroke_match ? 'Yes' : 'No'}
                        </td>
                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                          {attempt.location_match ? 'Yes' : 'No'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}
