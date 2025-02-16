import React, { useState, useRef, useEffect } from 'react';
import { KeystrokeData } from '../types';
import { RefreshCw } from 'lucide-react';

interface Props {
  text: string;
  onComplete: (keystrokes: KeystrokeData[]) => void;
}

export default function KeystrokeInput({ text, onComplete }: Props) {
  const [input, setInput] = useState('');
  const [keystrokes, setKeystrokes] = useState<KeystrokeData[]>([]);
  const [error, setError] = useState('');
  const startTime = useRef(Date.now());
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const resetTest = () => {
    setInput('');
    setKeystrokes([]);
    setError('');
    startTime.current = Date.now();
    if (textareaRef.current) {
      textareaRef.current.focus();
    }
  };

  useEffect(() => {
    if (input.length === text.length) {
      onComplete(keystrokes);
    }
  }, [input, keystrokes, text, onComplete]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (input.length >= text.length) return;
    
    const expectedChar = text[input.length];
    if (e.key !== expectedChar) {
      setError(`Expected "${expectedChar}" but got "${e.key}"`);
      return;
    }

    setError('');
    const pressTime = Date.now() - startTime.current;
    setKeystrokes(prev => [...prev, { key: e.key, press_time: pressTime, release_time: 0 }]);
  };

  const handleKeyUp = (e: React.KeyboardEvent) => {
    if (input.length > text.length) return;

    const releaseTime = Date.now() - startTime.current;
    setKeystrokes(prev => 
      prev.map((k, i) => 
        i === prev.length - 1 ? { ...k, release_time: releaseTime } : k
      )
    );
    setInput(prev => prev + e.key);
  };

  return (
    <div className="w-full max-w-lg">
      <div className="mb-4 p-4 bg-gray-100 rounded relative">
        <p className="text-gray-600 font-medium">{text}</p>
        <button
          onClick={resetTest}
          className="absolute top-2 right-2 p-2 text-gray-500 hover:text-gray-700 transition-colors"
          title="Reset typing test"
        >
          <RefreshCw className="w-4 h-4" />
        </button>
      </div>
      <textarea
        ref={textareaRef}
        className="w-full p-4 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
        rows={3}
        value={input}
        onChange={() => {}} // Required for controlled component
        onKeyDown={handleKeyDown}
        onKeyUp={handleKeyUp}
        placeholder="Start typing..."
      />
      {error && (
        <p className="mt-2 text-red-500">{error}</p>
      )}
      <div className="mt-2 text-gray-600">
        Progress: {input.length}/{text.length} characters
      </div>
    </div>
  );
}
