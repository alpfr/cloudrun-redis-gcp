import os
import logging
from flask import Flask, jsonify
import redis

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Fetch Redis configurations from environment variables
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
REDIS_DB = int(os.getenv("REDIS_DB", 0))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD", None)

# Initialize Redis client
try:
    r = redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        db=REDIS_DB,
        password=REDIS_PASSWORD,
        socket_timeout=5,
        decode_responses=True
    )
except Exception as e:
    logger.error(f"Failed to initialize Redis client: {e}")

@app.route('/')
def index():
    try:
        # Increment counter in Redis
        count = r.incr('visitor_count')
        logger.info(f"Successfully connected to Redis. Current visitor count: {count}")
        return jsonify({
            "status": "success",
            "message": "Connected to Redis successfully!",
            "visitor_count": count,
            "connected_to": f"{REDIS_HOST}:{REDIS_PORT}"
        })
    except redis.ConnectionError as e:
        logger.error(f"Redis connection error: {e}")
        return jsonify({
            "status": "error",
            "message": f"Could not connect to Redis: {str(e)}",
            "connected_to": f"{REDIS_HOST}:{REDIS_PORT}"
        }), 503
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return jsonify({
            "status": "error",
            "message": f"An unexpected error occurred: {str(e)}"
        }), 500

@app.route('/healthz')
def healthz():
    try:
        r.ping()
        return jsonify({"status": "healthy"}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "error": str(e)}), 503

if __name__ == '__main__':
    # For development only. Gunicorn is used for production.
    app.run(host='0.0.0.0', port=5000)
