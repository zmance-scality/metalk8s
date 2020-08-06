import React, { useEffect } from 'react';
import { useSelector, useDispatch } from 'react-redux';
import { ThemeProvider } from 'styled-components';
import { useRouteMatch, useHistory } from 'react-router';
import { Switch } from 'react-router-dom';
import { Layout as CoreUILayout, Notifications } from '@scality/core-ui';

import { intl } from '../translations/IntlGlobalProvider';
import NodeCreateForm from './NodeCreateForm';
import NodeList from './NodeList';
import SolutionList from './SolutionList';
import EnvironmentCreationForm from './EnvironmentCreationForm';
import NodeInformation from './NodeInformation';
import NodeDeployment from './NodeDeployment';
import ClusterMonitoring from './ClusterMonitoring';
import About from './About';
import PrivateRoute from './PrivateRoute';
import VolumePage from './VolumePage';

import { toggleSideBarAction } from '../ducks/app/layout';

import { removeNotificationAction } from '../ducks/app/notifications';
import { updateLanguageAction, logoutAction } from '../ducks/config';
import { FR_LANG, EN_LANG } from '../constants';
import CreateVolume from './CreateVolume';
import VolumeInformation from './VolumeInformation';
import { useRefreshEffect } from '../services/utils';
import {
  refreshSolutionsAction,
  stopRefreshSolutionsAction,
} from '../ducks/app/solutions';
import { fetchClusterVersionAction } from '../ducks/app/nodes';

const Layout = (props) => {
  const user = useSelector((state) => state.oidc.user);
  const sidebar = useSelector((state) => state.app.layout.sidebar);
  const { theme, language } = useSelector((state) => state.config);
  const notifications = useSelector((state) => state.app.notifications.list);
  const solutions = useSelector((state) => state.app.solutions.solutions);
  const dispatch = useDispatch();

  const logout = (event) => {
    event.preventDefault();
    dispatch(logoutAction());
  };

  const removeNotification = (uid) => dispatch(removeNotificationAction(uid));
  const updateLanguage = (language) => dispatch(updateLanguageAction(language));
  const toggleSidebar = () => dispatch(toggleSideBarAction());
  const history = useHistory();
  const api = useSelector((state) => state.config.api);
  useRefreshEffect(refreshSolutionsAction, stopRefreshSolutionsAction);
  useEffect(() => {
    dispatch(fetchClusterVersionAction());
  }, [dispatch]);

  const sidebarConfig = {
    onToggleClick: toggleSidebar,
    expanded: sidebar.expanded,
    actions: [
      {
        label: intl.translate('monitoring'),
        icon: <i className="fas fa-desktop" />,
        onClick: () => {
          history.push('/');
        },
        active: useRouteMatch({
          path: '/',
          exact: true,
          strict: true,
        }),
      },
      {
        label: intl.translate('nodes'),
        icon: <i className="fas fa-server" />,
        onClick: () => {
          history.push('/nodes');
        },
        active: useRouteMatch({
          path: '/nodes',
          exact: false,
          strict: true,
        }),
      },
      // deactive the access to the global volumes page now, we can only access the volume page through the node page
      // {
      //   label: intl.translate('volumes'),
      //   icon: <i className="fas fa-database" />,
      //   onClick: () => {
      //     history.push('/volumes');
      //   },
      //   active: useRouteMatch({
      //     path: '/volumes',
      //     exact: false,
      //     strict: true,
      //   }),
      // },
      // need to remove the solutions since it's not working in 2.5 or should be backported
      {
        label: intl.translate('solutions'),
        icon: <i className="fas fa-th" />,
        onClick: () => {
          history.push('/solutions');
        },
        active: useRouteMatch({
          path: '/solutions',
          exact: false,
          strict: true,
        }),
      },
    ],
  };

  let applications = null;
  if (solutions?.length) {
    applications = solutions?.reduce((prev, solution) => {
      let solutionDeployedVersions = solution?.versions?.filter(
        (version) => version?.deployed && version?.ui_url,
      );
      let app = solutionDeployedVersions.map((version) => ({
        label: solution.name,
        // TO BE IMPROVED in core-ui to allow display Link or <a></a>
        onClick: () => window.open(version.ui_url, '_self'),
      }));
      return [...prev, ...app];
    }, []);
  }

  // In this particular case, the label should not be translated
  const languages = [
    {
      label: 'Français',
      name: FR_LANG,
      onClick: () => {
        updateLanguage(FR_LANG);
      },
      selected: language === FR_LANG,
      'data-cy': FR_LANG,
    },
    {
      label: 'English',
      name: EN_LANG,
      onClick: () => {
        updateLanguage(EN_LANG);
      },
      selected: language === EN_LANG,
      'data-cy': EN_LANG,
    },
  ];

  const filterLanguage = languages.filter((lang) => lang.name !== language);

  const rightActions = [
    {
      type: 'dropdown',
      text: language,
      icon: <i className="fas fa-globe" />,
      items: filterLanguage,
    },
    {
      type: 'dropdown',
      icon: <i className="fas fa-question-circle" />,
      items: [
        {
          label: intl.translate('about'),
          onClick: () => {
            history.push('/about');
          },
        },
        {
          label: intl.translate('documentation'),
          onClick: () => {
            window.open(`${api.url_doc}/index.html`);
          },
          'data-cy': 'documentation',
        },
      ],
    },
    {
      type: 'dropdown',
      text: user?.profile?.name,
      icon: <i className="fas fa-user" />,
      'data-cy': 'user_dropdown',
      items: [
        {
          label: intl.translate('log_out'),
          onClick: (event) => logout(event),
          'data-cy': 'logout_button',
        },
      ],
    },
  ];

  const applicationsAction = {
    type: 'dropdown',
    icon: <i className="fas fa-th" />,
    items: applications,
  };

  if (applications && applications.length) {
    rightActions.splice(1, 0, applicationsAction);
  }

  const navbar = {
    productName: intl.translate('product_name'),
    rightActions,
    logo: <img alt="logo" src={process.env.PUBLIC_URL + theme.logo_path} />,
  };

  return (
    <ThemeProvider theme={theme}>
      <CoreUILayout sidebar={sidebarConfig} navbar={navbar}>
        <Notifications
          notifications={notifications}
          onDismiss={removeNotification}
        />
        <Switch>
          <PrivateRoute exact path="/nodes/create" component={NodeCreateForm} />
          <PrivateRoute
            exact
            path="/nodes/:id/deploy"
            component={NodeDeployment}
          />
          <PrivateRoute
            path={`/nodes/:id/createVolume`}
            component={CreateVolume}
          />
          {/* <PrivateRoute
            path="/nodes/:id/volumes/:volumeName"
            component={VolumeInformation}
          /> */}
          {/* New Volume Page to replace the volumeInformation page */}
          <PrivateRoute
            path="/nodes/:id/volumes/:volumeName"
            component={VolumePage}
          />
          <PrivateRoute path="/nodes/:id" component={NodeInformation} />
          <PrivateRoute exact path="/nodes" component={NodeList} />
          <PrivateRoute exact path="/solutions" component={SolutionList} />
          <PrivateRoute exact path="/volumes" component={VolumePage} />
          <PrivateRoute
            exact
            path="/solutions/create-environment"
            component={EnvironmentCreationForm}
          />
          <PrivateRoute exact path="/about" component={About} />
          <PrivateRoute exact path="/" component={ClusterMonitoring} />
        </Switch>
      </CoreUILayout>
    </ThemeProvider>
  );
};

export default Layout;
