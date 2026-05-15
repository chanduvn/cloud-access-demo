import os
import pyodbc
from flask import Flask, render_template_string, request

app = Flask(__name__)

# Fetch database credentials from Environment Variables (injected by Key Vault)
DB_SERVER = os.environ.get('DB_SERVER')
DB_DATABASE = os.environ.get('DB_DATABASE')
DB_USERNAME = os.environ.get('DB_USERNAME')
DB_PASSWORD = os.environ.get('DB_PASSWORD')

def get_db_connection():
    # Azure Linux Web Apps have the ODBC Driver 17 for SQL Server pre-installed
    conn_str = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={DB_SERVER};DATABASE={DB_DATABASE};UID={DB_USERNAME};PWD={DB_PASSWORD}"
    return pyodbc.connect(conn_str)

# HTML Template for our simple form
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head><title>Demo App</title></head>
<body style="font-family: Arial, sans-serif; margin: 40px;">
    <h2>Safeguard Demo Application</h2>
    <p>Connected to Azure SQL Database securely!</p>
    
    <form method="POST" action="/">
        <input type="text" name="message" placeholder="Enter a message" required>
        <button type="submit">Save to Database</button>
    </form>
    
    <h3>Stored Messages:</h3>
    <ul>
        {% for row in rows %}
            <li>{{ row.message }} <em>(Saved at: {{ row.created_at }})</em></li>
        {% endfor %}
    </ul>
</body>
</html>
"""

@app.route('/', methods=['GET', 'POST'])
def index():
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Auto-create table if it doesn't exist
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='Messages' AND xtype='U')
            CREATE TABLE Messages (
                id INT IDENTITY(1,1) PRIMARY KEY,
                message NVARCHAR(255),
                created_at DATETIME DEFAULT GETDATE()
            )
        """)
        conn.commit()

        # Handle form submission
        if request.method == 'POST':
            msg = request.form['message']
            cursor.execute("INSERT INTO Messages (message) VALUES (?)", msg)
            conn.commit()

        # Fetch all messages
        cursor.execute("SELECT message, created_at FROM Messages ORDER BY id DESC")
        rows = cursor.fetchall()
        conn.close()
        
        return render_template_string(HTML_TEMPLATE, rows=rows)
        
    except Exception as e:
        return f"<h3>Database Connection Error:</h3><p>{str(e)}</p>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)