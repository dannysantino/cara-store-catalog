import { useEffect, useState } from 'react'

import axios from 'axios'
import { Link } from 'react-router'

import { API_URL } from '../config'

const Products = () => {
    const [products, setProducts] = useState([]);

    const handleDelete = async id => {
        try {
            await axios.delete(`${API_URL}/products/${id}`);
            window.location.reload();
        } catch (err) {
            console.error(err);
        }
    }

    useEffect(() => {
        (async function () {
            try {
                const res = await axios.get(`${API_URL}/products`);
                setProducts(res.data);
            } catch (err) {
                console.error(err);
            }
        })();
    }, []);

    return (
        <>
            <section>
                <div className="container">
                    <div className="row mt-3">
                        <div className="col text-end">
                            <Link to="/add" className="btn btn-primary btn-lg">Add Product</Link>
                        </div>
                    </div>
                </div>
            </section>

            <section className="page-header">
                <div className="container">
                    <div className="row">
                        <div className="col text-center">
                            <h3>Products</h3>
                            <p className="mb-4">Check out our collection of products</p>
                        </div>
                    </div>
                </div>
            </section>

            <section id="products">
                <div className="container mb-5">
                    <div className="row row-cols-1 row-cols-md-3 g-4 justify-content-center">
                        {products.length === 0
                            ? <h3 className="text-center">No products available at this time. Please check back later!</h3>
                            : (
                                products.map(product => (
                                    <div className="col" key={product.id}>
                                        <div className="card h-100">
                                            <img src={product.img} alt={product.name} className="card-img-top" />
                                            <div className="card-body">
                                                <h5 className="card-title">{product.name}</h5>
                                                <p className="fw-bold">${product.price}</p>
                                                <p className="card-text">{product.description}</p>
                                                <Link to={`/update/${product.id}`} className="btn btn-info">Update</Link>
                                                <Link onClick={() => handleDelete(product.id)} className="btn btn-danger ms-3">Delete</Link>
                                            </div>
                                        </div>
                                    </div>
                                ))
                            )}
                    </div>
                </div>
            </section>
        </>
    )
}

export default Products