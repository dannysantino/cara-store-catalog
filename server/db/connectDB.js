import mysql from "mysql"

const mysqlHost = process.env.MYSQL_HOST,
    mysqlUser = process.env.MYSQL_USER,
    mysqlPassword = process.env.MYSQL_PASSWORD,
    mysqlDB = process.env.MYSQL_DATABASE;

let db = null;
let attempt = 1;
let retries = 5;

function connectToDB(config) {
    return new Promise((resolve, reject) => {
        const connection = mysql.createConnection(config);
        connection.connect(err => {
            if (err) {
                connection.end();
                reject(err);
            } else {
                resolve(connection);
            }
        });
    });
}

function delayRetry(ms) {
    return new Promise(res => setTimeout(res, ms));
}

export async function initDB() {
    const config = {
        host: mysqlHost,
        user: mysqlUser,
        password: mysqlPassword,
        database: mysqlDB
    }

    while (attempt <= retries) {
        try {
            console.log(`Attempting DB connection: ${attempt} of ${retries}`);
            db = await connectToDB(config);
            console.log(`DB connected: ${db.threadId}`);
            return;
        } catch (err) {
            attempt++
            console.error(`DB connection failed: ${err.stack}`);
            if (attempt <= retries)
                await delayRetry(5000);
        }
    }

    throw new Error("Failed to establish DB connection after maximum retries.");
}

export function getDB() {
    if (!db) throw new Error("DB not initialised.");
    return db;
}