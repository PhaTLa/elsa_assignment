#!/usr/bin/env python3
"""
Quote API Service
Minimal HTTP service with health checks, metrics, and motivational quotes.
"""

import time
import random
from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

# Prometheus metrics
request_count = Counter(
    'quote_api_requests_total',
    'Total API requests',
    ['method', 'endpoint', 'status']
)
request_duration = Histogram(
    'quote_api_request_duration_seconds',
    'Request duration in seconds',
    ['endpoint']
)

# Quotes dataset (minimal, in-memory)
QUOTES = [
    ("You are capable of amazing things.", "Unknown"),
    ("The only way to do great work is to love what you do.", "Steve Jobs"),
    ("Innovation distinguishes between a leader and a follower.", "Steve Jobs"),
    ("Life is what happens when you're busy making other plans.", "John Lennon"),
    ("The future belongs to those who believe in the beauty of their dreams.", "Eleanor Roosevelt"),
    ("It is during our darkest moments that we must focus to see the light.", "Aristotle"),
    ("The only impossible journey is the one you never begin.", "Tony Robbins"),
    ("In the end, we will remember not the words of our enemies, but the silence of our friends.", "Martin Luther King Jr."),
]


@app.route('/healthz', methods=['GET'])
def healthz():
    """Liveness probe: always ready."""
    request_count.labels(method='GET', endpoint='/healthz', status=200).inc()
    return jsonify({'status': 'alive'}), 200


@app.route('/readyz', methods=['GET'])
def readyz():
    """Readiness probe: service is ready."""
    request_count.labels(method='GET', endpoint='/readyz', status=200).inc()
    return jsonify({'status': 'ready'}), 200


@app.route('/metrics', methods=['GET'])
def metrics():
    """Prometheus metrics endpoint."""
    request_count.labels(method='GET', endpoint='/metrics', status=200).inc()
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}


@app.route('/api/quote', methods=['GET'])
def quote():
    """
    Return a random motivational quote with ~100ms CPU work.
    Simulates actual service workload for load testing.
    """
    start = time.time()

    # Simulate 100ms of CPU work (e.g., processing, validation)
    end_time = start + 0.1
    while time.time() < end_time:
        _ = sum(i * i for i in range(1000))

    # Select random quote
    quote_text, author = random.choice(QUOTES)

    elapsed = time.time() - start
    request_duration.labels(endpoint='/api/quote').observe(elapsed)
    request_count.labels(method='GET', endpoint='/api/quote', status=200).inc()

    return jsonify({
        'quote': quote_text,
        'author': author,
        'elapsed_ms': round(elapsed * 1000, 2)
    }), 200


@app.errorhandler(404)
def not_found(error):
    """Handle 404 errors."""
    request_count.labels(method='GET', endpoint='unknown', status=404).inc()
    return jsonify({'error': 'Not found'}), 404


@app.errorhandler(500)
def internal_error(error):
    """Handle 500 errors."""
    request_count.labels(method='GET', endpoint='unknown', status=500).inc()
    return jsonify({'error': 'Internal server error'}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, debug=False)
