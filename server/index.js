import "dotenv/config"

import express from "express"
import cors from "cors"

import { initDB, getDB } from "./db/connectDB.js"

const app = express();

app.use(cors());
app.use(express.json());

try {
    await initDB();
} catch (err) {
    console.error(err.message);
    process.exit(1);
}

const db = getDB();

app.get("/", (req, res) => {
    res.json("Hello from the server!");
});

app.get("/products", (_, res) => {
    let q = "SELECT * FROM products";
    db.query(q, (err, results) => {
        if (err) return res.status(500).json({ error: err.sqlMessage });
        res.json(results);
    });
});

app.post("/products", (req, res) => {
    let { name, description, price, img } = req.body;
    let values = [name, description, price, img];
    let q = "INSERT INTO products (`name`, `description`, `price`, `img`) VALUES (?)";

    db.query(q, [values], (err, result) => {
        if (err) {
            console.error(err);
            return res.status(500).json({ error: err.sqlMessage });
        }
        res.json(result);
    });
});

app.put("/products/:id", (req, res) => {
    let { id } = req.params;
    let { name, description, price, img } = req.body;
    let values = [name, description, price, img];
    let q = "UPDATE products SET `name` = ?, `description` = ?, `price` = ?, `img` = ? WHERE id = ?";

    db.query(q, [...values, id], (err, result) => {
        if (err) {
            console.error(err);
            return res.status(500).json({ error: err.sqlMessage });
        }
        res.json(result);
    });
});

app.delete("/products/:id", (req, res) => {
    let { id } = req.params;
    let q = "DELETE FROM products WHERE id = ?";

    db.query(q, [id], (err, result) => {
        if (err) return res.status(500).json({ error: err.sqlMessage });
        res.json(result);
    });
});

export { app, db }