import axios from 'axios';
import { KeystrokeData } from './types';

const API_URL = 'http://localhost:5000';

export const api = {
  signup: async (email: string, password: string, keystrokes: KeystrokeData[]) => {
    const signupResponse = await axios.post(`${API_URL}/signup`, { email, password });
    if (signupResponse.status === 200) {
      return axios.post(`${API_URL}/collect-keystrokes`, { email, keystrokes });
    }
    throw new Error('Signup failed');
  },

  login: async (email: string, password: string, keystrokes: KeystrokeData[]) => {
    const loginResponse = await axios.post(`${API_URL}/validate-keystrokes`, {
      email,
      password,
      keystrokes,
    });
    return loginResponse.data;
  },
};
