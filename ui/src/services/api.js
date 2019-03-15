import axios from 'axios';
import { Config, Core_v1Api } from '@kubernetes/client-node';

const api = axios.create({
  baseURL: 'https://localhost:8080/api/v1',
  timeout: 1000
});

//Basic Auth
export async function authenticate({ username, password }) {
  localStorage.removeItem('token');
  const token = btoa(username + ':' + password); //base64Encode
  try {
    await api.get('/', {
      headers: {
        Authorization: 'Basic ' + token
      }
    });
    localStorage.setItem('token', token);
    return {
      response: {
        username,
        password,
        token
      }
    };
  } catch (errors) {
    return { errors: errors.response.data };
  }
}

export const logout = () => {
  localStorage.removeItem('token');
};

export async function getNodes({ token }) {
  const config = new Config('https://localhost:8080', token, 'Basic');
  const coreV1 = config.makeApiClient(Core_v1Api);
  try {
    return await coreV1.listNode();
  } catch (error) {
    console.error('Error retrieving nodes', error.body ? error.body : error);
  }
}
