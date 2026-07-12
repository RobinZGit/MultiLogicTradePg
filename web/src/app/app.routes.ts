import { Routes } from '@angular/router';
import { LogicsComponent } from './logics/logics.component';

export const routes: Routes = [
  { path: '', component: LogicsComponent },
  { path: '**', redirectTo: '' },
];
