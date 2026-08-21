import os
import pyodbc
from flask import Flask, render_template_string, request

app = Flask(__name__)

DB_SERVER = os.environ.get('DB_SERVER')
DB_DATABASE = os.environ.get('DB_DATABASE')
AZURE_CLIENT_ID = os.environ.get('AZURE_CLIENT_ID')

def get_db_connection():
    # Passwordless: authenticates as the Web App's user-assigned managed identity
    # via Azure AD, granted db_datareader/db_datawriter out-of-band by
    # scripts/grant-sql-access.py. No password anywhere in this app.
    #
    # UID must carry the identity's client ID: a user-assigned identity is not
    # implicit the way a system-assigned one is, so the driver has to be told which
    # identity to present.
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={DB_SERVER};DATABASE={DB_DATABASE};"
        f"Authentication=ActiveDirectoryMsi;UID={AZURE_CLIENT_ID};Encrypt=yes;"
    )
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

        # The Messages table is created at provisioning time, not here. The app's
        # identity holds only db_datareader/db_datawriter -- deliberately, since the
        # whole point is least privilege -- so it cannot issue DDL, and an app that
        # rewrites its own schema on every request isn't a pattern worth showing.

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